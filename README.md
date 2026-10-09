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

A run without batches:

```sql
begin
    pkg_deltaplan.initialize('customer_metrics', 'all', 2);
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

    -- The mart statement reads deltaplan_keys_tmp
    -- where target_table = pkg_deltaplan.get_target_table
    --   and data_segment = pkg_deltaplan.get_data_segment

    pkg_deltaplan.finalize;
end;
```

A run in batches:

```sql
pkg_deltaplan.prepare_batches(5000);
while pkg_deltaplan.next_batch loop
    -- merge, insert, update, or delete against deltaplan_batch_tmp
    pkg_deltaplan.finish_batch;
end loop;
pkg_deltaplan.finalize;
```

A complete session is in `examples/oracle/example_customer_metrics.sql`. `examples/oracle/seed_volume.sql` loads a large source and is not part of the tests.

## PostgreSQL

The routines are functions in schema `deltaplan`. They do not commit, so they run on PostgreSQL and on Greenplum releases that forbid a commit inside a function. `deltaplan_watermark` is created in `public`. `initialize` creates the temporary tables for the session. If that transaction is rolled back, the temporary tables are dropped with it, and `initialize` must be called again.

Tables live in `ddl_dml/`, routines in `functions/`.

```bash
psql "postgresql://user:password@localhost:5432/db" -f postgres/install.sql
```

From SQL, call them with `select`. From PL/pgSQL, use `perform`. `next_batch` returns boolean, so a `WHILE` loop works inside a `DO` block. `next_batch`, the mart statement, and `finish_batch` must run in one transaction: a commit empties `deltaplan_batch_tmp` before the statement can read it. `finish_batch` takes an optional row count, `p_merged`, because it cannot see the caller's `ROW_COUNT`.

A run without batches:

```sql
select deltaplan.initialize('customer_metrics', 'all', 2);
select deltaplan.capture_delta('orders', $sql$
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

-- The mart statement reads deltaplan_keys_tmp
-- where target_table = deltaplan.get_target_table()
--   and data_segment = deltaplan.get_data_segment()

select deltaplan.finalize();
```

A run in batches, inside a `DO` block:

```sql
perform deltaplan.prepare_batches(5000);
while deltaplan.next_batch() loop
    -- update or insert against deltaplan_batch_tmp
    perform deltaplan.finish_batch();
end loop;
perform deltaplan.finalize();
```

A complete session is in `examples/postgres/example_customer_metrics.sql`. The load there is `UPDATE` followed by `INSERT`.

### Greenplum

The same file installs on Greenplum 7. The functions do not commit. Greenplum has no `MERGE`. `deltaplan_watermark` is `DISTRIBUTED BY (target_table)`, and the temporary key tables are `DISTRIBUTED BY (pk_1)`. The suite was run on PostgreSQL 15.4. A Greenplum cluster was not started here.

## Tests

Oracle, with SQL\*Plus:

```bash
make test-oracle
```

`ORACLE_CONNECT` defaults to `test/test_pass@//localhost:1521/test_db`.

PostgreSQL, with `psql` inside a container. The host does not need `psql`. `tests/postgres/run.sh` copies the scripts into the container.

```bash
make test-postgres
```

`PG_CONTAINER`, `PGUSER`, `PGPASSWORD`, and `PGDATABASE` default to `postgres`, `test_user`, `test_pass`, and `test_db`.

A fresh pair of databases, on ports that do not collide with 1521 and 5433:

```bash
docker compose -f tests/docker/docker-compose.yml up --wait
ORACLE_CONNECT=test/test_pass@//localhost:1522/FREEPDB1 make test-oracle
PG_CONTAINER=deltaplan-postgres make test-postgres
```

The Oracle image is [gvenzl/oracle-free](https://github.com/gvenzl/oci-oracle-free). It does not require an Oracle registry login. The first start takes several minutes.

Both suites cover a static load, the lookback window, batches, a resume after rollback, and the errors that keep a watermark in place. The passing lines are `pkg_deltaplan_test: passed` and `deltaplan_test: passed`.
