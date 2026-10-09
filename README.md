# deltaplan

Deltaplan is a small library for incremental mart loads on Oracle and PostgreSQL. It keeps a watermark for each source, captures the primary keys that have moved since that watermark, and leaves the mart statement to you. You recalculate only those keys. Deltaplan never moves a watermark backwards.

The mart statement is ordinary SQL. Batches are optional: a small mart can be refreshed in one statement; a large one can be split into committed slices.

## How a run works

1. Call `initialize` with the target table, a data segment (default `all`), and a lookback in hours (default `0`).
2. Call `capture_delta` once for each source. Each call inserts keys into `deltaplan_keys_tmp`.
3. Refresh the mart for those keys. Without batches, one statement reads `deltaplan_keys_tmp`. With batches, each statement reads `deltaplan_batch_tmp`.
4. Call `finalize`. It writes, for each source, the greatest watermark captured in this run.

The capture statement must return four columns: `pk_1`, `pk_2`, `pk_3`, and `watermark`. Leave `pk_2` and `pk_3` null when the key is shorter. The statement must contain the placeholder `:since` exactly once. `:since` is the stored watermark minus the lookback; it is not the stored watermark itself. The predicate remains strict: `value > :since`. The lookback is applied when the bound is read and is not stored.

A key that arrives from several sources is assigned to a single batch.

## Data segments

A watermark is stored for the triple `(target_table, data_segment, source_table)`. The default segment is `all`, which is enough when the mart is loaded as one unit.

Use a named segment when the same target must be loaded in independent slices. Typical cases are a country, a legal entity, or a book of business. Each slice then has its own watermark, so a late load for France does not hold back Germany, and a rerun of one slice does not recapture keys of another.

Deltaplan does not read `data_segment` out of the source tables. You pass the slice into `initialize`, and you apply the same predicate in the capture SQL and in the mart statement. `get_data_segment` returns the value of the current run, so the statements stay aligned.

```sql
pkg_deltaplan.initialize('customer_metrics', 'fr', 2);

pkg_deltaplan.capture_delta('orders', q'[
    select customer_id as pk_1,
           null        as pk_2,
           null        as pk_3,
           max(updated_at) as watermark
    from orders
    where country_code = pkg_deltaplan.get_data_segment
      and updated_at > :since
    group by customer_id
]');
```

The mart statement for a run without batches still restricts `deltaplan_keys_tmp` to that segment:

```sql
where k.target_table = pkg_deltaplan.get_target_table
  and k.data_segment = pkg_deltaplan.get_data_segment
```

`deltaplan_batch_tmp` does not store the segment: it contains only the keys of the open batch, which already belong to the current run. A second session may call `initialize` for another segment of the same target; the watermarks remain separate.

## Hard deletes

Hard deletes are not supported.

Capture can return a key only while that key still exists in the source and its watermark is greater than `:since`. A physical `DELETE` removes the source row, so the key never reaches `deltaplan_keys_tmp` and the mart row is left unchanged.

If a removal must reach the mart, keep a row in the source: a deleted flag, a tombstone, or an audit record, with a watermark that continues to move. The mart statement then deletes or updates the corresponding key.

## Tables

The tables have the same names and the same column order on Oracle and PostgreSQL. Session tables take the suffix `_tmp`, the usual warehouse marker for a temporary relation. `_gtt` is not used: it would describe Oracle only, while PostgreSQL and Greenplum use session `TEMP` tables.

`deltaplan_watermark` is permanent. There is one row for each combination of target, segment, and source. `finalize` advances `watermark` and sets `updated_at`.

| Column | Meaning |
| --- | --- |
| `target_table`, `data_segment`, `source_table` | Grain of the row |
| `watermark` | Greatest source value that has been fully applied |
| `updated_at` | Time at which `finalize` last wrote the row |

`deltaplan_keys_tmp` holds every key captured in the current run. The rows survive a commit and last until the session ends. A run without batches reads this table, restricted to the current target and segment.

| Column | Meaning |
| --- | --- |
| `target_table`, `data_segment`, `source_table` | Same grain as `deltaplan_watermark` |
| `pk_1`, `pk_2`, `pk_3` | Business key of the mart row |
| `watermark` | Source value of this key |
| `batch_no`, `batch_done` | Filled by `prepare_batches`. `batch_done` becomes `1` after `finish_batch` |

`deltaplan_batch_tmp` holds the business key of the open batch: `pk_1`, `pk_2`, `pk_3`, in the same order as in `deltaplan_keys_tmp`. A commit empties the table. The mart statement of a batched run reads this table.

## Batches

`prepare_batches` numbers the distinct keys. The default size is `5000`.

The loop is then `next_batch`, the mart statement against `deltaplan_batch_tmp`, and `finish_batch`. Call `finish_batch` immediately after that statement. `next_batch` returns false when no unfinished batch remains. Call `finalize` after the loop. It raises an error while a batch is unfinished, and that error does not roll the session back.

On Oracle, when `p_commit` is true, which is the default, the captured keys are committed first and each `finish_batch` commits its own batch. A later call in the same session resumes at the unfinished batch. After a rollback `deltaplan_batch_tmp` is empty, and the next `next_batch` returns that same batch.

On PostgreSQL the functions do not commit. Commit after `prepare_batches` if a later rollback should keep the captured keys, and after each `finish_batch` if it should keep that batch. `next_batch`, the mart statement, and `finish_batch` stay in one transaction: `deltaplan_batch_tmp` is emptied on commit.

## Oracle

Install from `oracle/`. SQL\*Plus resolves `@@` against the working directory. Tables live in `ddl_dml/`, the package in `packages/`, as in `rpd_data/lib` and `dwh_ato/lib`.

```bash
cd oracle
sqlplus user/password@//host:1521/service @install.sql
```

This creates `deltaplan_watermark`, the two global temporary tables, and `pkg_deltaplan`. The calculating user must own them. The package keeps its position in the session, so a rollback does not forget which batch was open. The `finish_batch` log line records `sql%rowcount` of the preceding statement.

A run without batches. The merge reads `deltaplan_keys_tmp`, restricted to the current target and segment:

```sql
declare
    l_change_date date;
begin
    pkg_deltaplan.initialize('customer_metrics', 'all', 2);

    pkg_deltaplan.capture_delta('customers', q'[
        with changed_customers as (
            select id, updated_at
            from customers
            where updated_at > :since
        )
        select id as pk_1,
               null as pk_2,
               null as pk_3,
               updated_at as watermark
        from changed_customers
    ]');

    pkg_deltaplan.capture_delta('orders', q'[
        with changed_orders as (
            select customer_id, updated_at
            from orders
            where updated_at > :since
        )
        select customer_id as pk_1,
               null        as pk_2,
               null        as pk_3,
               max(updated_at) as watermark
        from changed_orders
        group by customer_id
    ]');

    pkg_deltaplan.capture_delta('order_items', q'[
        with changed_items as (
            select order_id, updated_at
            from order_items
            where updated_at > :since
        )
        select o.customer_id as pk_1,
               null          as pk_2,
               null          as pk_3,
               max(ci.updated_at) as watermark
        from changed_items ci
        join orders o on o.id = ci.order_id
        group by o.customer_id
    ]');

    l_change_date := sysdate;

    merge into customer_metrics t
        using (
            with changed as (
                select pk_1 as customer_id
                from deltaplan_keys_tmp
                where target_table = pkg_deltaplan.get_target_table
                  and data_segment = pkg_deltaplan.get_data_segment
                group by pk_1
            )
            select c.id as customer_id,
                   min(oi.quantity * oi.price * (1 - o.order_discount)) as min_amount,
                   max(oi.quantity * oi.price * (1 - o.order_discount)) as max_amount,
                   avg(oi.quantity * oi.price * (1 - o.order_discount)) as avg_amount,
                   count(case when o.status = 'completed' then 1 end) as cnt_completed
            from customers c
            join changed ch on ch.customer_id = c.id
            join orders o on o.customer_id = c.id
            join order_items oi on oi.order_id = o.id
            group by c.id
        ) s
        on (s.customer_id = t.customer_id)
        when matched then update set
            t.min_amount     = s.min_amount,
            t.max_amount     = s.max_amount,
            t.avg_amount     = s.avg_amount,
            t.cnt_completed  = s.cnt_completed,
            t.mt_change_date = l_change_date
        when not matched then insert (
            customer_id, min_amount, max_amount, avg_amount,
            cnt_completed, mt_change_date
        ) values (
            s.customer_id, s.min_amount, s.max_amount, s.avg_amount,
            s.cnt_completed, l_change_date
        );

    pkg_deltaplan.finalize;
end;
```

A run in batches. The merge is the same, except that it reads `deltaplan_batch_tmp` and does not filter on target or segment: those keys already belong to the open batch.

```sql
declare
    l_change_date date;
begin
    pkg_deltaplan.initialize('customer_metrics', 'all', 2);

    pkg_deltaplan.capture_delta('customers', q'[
        with changed_customers as (
            select id, updated_at
            from customers
            where updated_at > :since
        )
        select id as pk_1,
               null as pk_2,
               null as pk_3,
               updated_at as watermark
        from changed_customers
    ]');

    pkg_deltaplan.capture_delta('orders', q'[
        with changed_orders as (
            select customer_id, updated_at
            from orders
            where updated_at > :since
        )
        select customer_id as pk_1,
               null        as pk_2,
               null        as pk_3,
               max(updated_at) as watermark
        from changed_orders
        group by customer_id
    ]');

    pkg_deltaplan.capture_delta('order_items', q'[
        with changed_items as (
            select order_id, updated_at
            from order_items
            where updated_at > :since
        )
        select o.customer_id as pk_1,
               null          as pk_2,
               null          as pk_3,
               max(ci.updated_at) as watermark
        from changed_items ci
        join orders o on o.id = ci.order_id
        group by o.customer_id
    ]');

    l_change_date := sysdate;
    pkg_deltaplan.prepare_batches(5000);

    while pkg_deltaplan.next_batch loop
        merge into customer_metrics t
            using (
                with changed as (
                    select pk_1 as customer_id
                    from deltaplan_batch_tmp
                    group by pk_1
                )
                select c.id as customer_id,
                       min(oi.quantity * oi.price * (1 - o.order_discount)) as min_amount,
                       max(oi.quantity * oi.price * (1 - o.order_discount)) as max_amount,
                       avg(oi.quantity * oi.price * (1 - o.order_discount)) as avg_amount,
                       count(case when o.status = 'completed' then 1 end) as cnt_completed
                from customers c
                join changed ch on ch.customer_id = c.id
                join orders o on o.customer_id = c.id
                join order_items oi on oi.order_id = o.id
                group by c.id
            ) s
            on (s.customer_id = t.customer_id)
            when matched then update set
                t.min_amount     = s.min_amount,
                t.max_amount     = s.max_amount,
                t.avg_amount     = s.avg_amount,
                t.cnt_completed  = s.cnt_completed,
                t.mt_change_date = l_change_date
            when not matched then insert (
                customer_id, min_amount, max_amount, avg_amount,
                cnt_completed, mt_change_date
            ) values (
                s.customer_id, s.min_amount, s.max_amount, s.avg_amount,
                s.cnt_completed, l_change_date
            );

        pkg_deltaplan.finish_batch;
    end loop;

    pkg_deltaplan.finalize;
end;
```

A session with three sources is in `examples/oracle/example_customer_metrics.sql`. `examples/oracle/seed_volume.sql` loads a large source and is not part of the tests.

## PostgreSQL

The routines are functions in schema `deltaplan`. They do not commit, so they run on PostgreSQL and on Greenplum releases that forbid a commit inside a function. `deltaplan_watermark` is created in `public`. `initialize` creates the temporary tables for the session. If that transaction is rolled back, the temporary tables are dropped with it, and `initialize` must be called again.

Tables live in `ddl_dml/`, routines in `functions/`.

```bash
psql "postgresql://user:password@localhost:5432/db" -f postgres/install.sql
```

From SQL, call them with `select`. From PL/pgSQL, use `perform`. `next_batch` returns boolean, so a `WHILE` loop works inside a `DO` block. `next_batch`, the mart statement, and `finish_batch` must run in one transaction: a commit empties `deltaplan_batch_tmp` before the statement can read it. `finish_batch` takes an optional row count, `p_merged`, because it cannot see the caller's `ROW_COUNT`.

A run without batches. `MERGE` is available on PostgreSQL 15 and later. The statement reads `deltaplan_keys_tmp`, restricted to the current target and segment:

```sql
do $run$
declare
    v_change_date timestamptz;
begin
    perform deltaplan.initialize('customer_metrics', 'all', 2);

    perform deltaplan.capture_delta('customers', $sql$
        with changed_customers as (
            select id, updated_at
            from customers
            where updated_at > :since
        )
        select id as pk_1,
               null::text as pk_2,
               null::text as pk_3,
               updated_at as watermark
        from changed_customers
    $sql$);

    perform deltaplan.capture_delta('orders', $sql$
        with changed_orders as (
            select customer_id, updated_at
            from orders
            where updated_at > :since
        )
        select customer_id as pk_1,
               null::text  as pk_2,
               null::text  as pk_3,
               max(updated_at) as watermark
        from changed_orders
        group by customer_id
    $sql$);

    perform deltaplan.capture_delta('order_items', $sql$
        with changed_items as (
            select order_id, updated_at
            from order_items
            where updated_at > :since
        )
        select o.customer_id as pk_1,
               null::text    as pk_2,
               null::text    as pk_3,
               max(ci.updated_at) as watermark
        from changed_items ci
        join orders o on o.id = ci.order_id
        group by o.customer_id
    $sql$);

    v_change_date := clock_timestamp();

    merge into customer_metrics t
    using (
        with changed as (
            select pk_1 as customer_id
            from deltaplan_keys_tmp
            where target_table = deltaplan.get_target_table()
              and data_segment = deltaplan.get_data_segment()
            group by pk_1
        )
        select c.id as customer_id,
               min(oi.quantity * oi.price * (1 - o.order_discount)) as min_amount,
               max(oi.quantity * oi.price * (1 - o.order_discount)) as max_amount,
               avg(oi.quantity * oi.price * (1 - o.order_discount)) as avg_amount,
               count(*) filter (where o.status = 'completed') as cnt_completed
        from customers c
        join changed ch on ch.customer_id = c.id
        join orders o on o.customer_id = c.id
        join order_items oi on oi.order_id = o.id
        group by c.id
    ) s
    on t.customer_id = s.customer_id
    when matched then update set
        min_amount     = s.min_amount,
        max_amount     = s.max_amount,
        avg_amount     = s.avg_amount,
        cnt_completed  = s.cnt_completed,
        mt_change_date = v_change_date
    when not matched then insert (
        customer_id, min_amount, max_amount, avg_amount,
        cnt_completed, mt_change_date
    ) values (
        s.customer_id, s.min_amount, s.max_amount, s.avg_amount,
        s.cnt_completed, v_change_date
    );

    perform deltaplan.finalize();
end;
$run$;
```

A run in batches, inside a `DO` block. The merge is the same, except that it reads `deltaplan_batch_tmp`.

```sql
do $run$
declare
    v_change_date timestamptz;
begin
    perform deltaplan.initialize('customer_metrics', 'all', 2);

    perform deltaplan.capture_delta('customers', $sql$
        with changed_customers as (
            select id, updated_at
            from customers
            where updated_at > :since
        )
        select id as pk_1,
               null::text as pk_2,
               null::text as pk_3,
               updated_at as watermark
        from changed_customers
    $sql$);

    perform deltaplan.capture_delta('orders', $sql$
        with changed_orders as (
            select customer_id, updated_at
            from orders
            where updated_at > :since
        )
        select customer_id as pk_1,
               null::text  as pk_2,
               null::text  as pk_3,
               max(updated_at) as watermark
        from changed_orders
        group by customer_id
    $sql$);

    perform deltaplan.capture_delta('order_items', $sql$
        with changed_items as (
            select order_id, updated_at
            from order_items
            where updated_at > :since
        )
        select o.customer_id as pk_1,
               null::text    as pk_2,
               null::text    as pk_3,
               max(ci.updated_at) as watermark
        from changed_items ci
        join orders o on o.id = ci.order_id
        group by o.customer_id
    $sql$);

    v_change_date := clock_timestamp();
    perform deltaplan.prepare_batches(5000);

    while deltaplan.next_batch() loop
        merge into customer_metrics t
        using (
            with changed as (
                select pk_1 as customer_id
                from deltaplan_batch_tmp
                group by pk_1
            )
            select c.id as customer_id,
                   min(oi.quantity * oi.price * (1 - o.order_discount)) as min_amount,
                   max(oi.quantity * oi.price * (1 - o.order_discount)) as max_amount,
                   avg(oi.quantity * oi.price * (1 - o.order_discount)) as avg_amount,
                   count(*) filter (where o.status = 'completed') as cnt_completed
            from customers c
            join changed ch on ch.customer_id = c.id
            join orders o on o.customer_id = c.id
            join order_items oi on oi.order_id = o.id
            group by c.id
        ) s
        on t.customer_id = s.customer_id
        when matched then update set
            min_amount     = s.min_amount,
            max_amount     = s.max_amount,
            avg_amount     = s.avg_amount,
            cnt_completed  = s.cnt_completed,
            mt_change_date = v_change_date
        when not matched then insert (
            customer_id, min_amount, max_amount, avg_amount,
            cnt_completed, mt_change_date
        ) values (
            s.customer_id, s.min_amount, s.max_amount, s.avg_amount,
            s.cnt_completed, v_change_date
        );

        perform deltaplan.finish_batch();
    end loop;

    perform deltaplan.finalize();
end;
$run$;
```

A session with three sources is in `examples/postgres/example_customer_metrics.sql`. That file uses `UPDATE` followed by `INSERT`, which also runs on Greenplum 7.

### Greenplum

The same file installs on Greenplum 7. The functions do not commit. Greenplum has no `MERGE`. `deltaplan_watermark` is `DISTRIBUTED BY (target_table)`, and the temporary key tables are `DISTRIBUTED BY (pk_1)`. The suite was run on PostgreSQL 15.4. A Greenplum cluster was not started here.

## Tests

Both suites copy the scripts into a database container. The host does not need `sqlplus` or `psql`.

```bash
docker compose -f tests/docker/docker-compose.yml up --wait
ORACLE_CONTAINER=deltaplan-oracle \
ORACLE_CONNECT=test/test_pass@//localhost:1521/FREEPDB1 \
PG_CONTAINER=deltaplan-postgres \
make test
```

`make` without those variables uses containers named `oracle` and `postgres`. `ORACLE_CONNECT` is passed into the Oracle container, so the host port does not appear in the string.

The Oracle image is [gvenzl/oracle-free](https://github.com/gvenzl/oci-oracle-free). It does not require an Oracle registry login. The first start takes several minutes.

GitHub Actions runs the same suites. Open **Actions**, choose **Tests**, and run the workflow. A push and a pull request start it as well.

Both suites cover a static load, the lookback window, batches, a resume after rollback, and the errors that keep a watermark in place. The passing lines are `pkg_deltaplan_test: passed` and `deltaplan_test: passed`.
