# PostgreSQL and Greenplum

Deploy and rollback: [deploy.md](deploy.md).

The routines are functions in schema `deltaplan`. They do not commit, so they run on PostgreSQL and on Greenplum releases that forbid a commit inside a function. `deltaplan_watermark` is created in `public`. `initialize` creates the temporary tables for the session. If that transaction is rolled back, the temporary tables are dropped with it, and `initialize` must be called again.

From SQL, call them with `select`. From PL/pgSQL, use `perform`. `next_batch` returns boolean, so a `WHILE` loop works inside a `DO` block. Commit after `prepare_batches` if a later rollback should keep the captured keys, and after each `finish_batch` if it should keep that batch. `next_batch`, the mart statement, and `finish_batch` stay in one transaction: a commit empties `deltaplan_batch_tmp` before the statement can read it. `finish_batch` takes an optional row count, `p_merged`, because it cannot see the caller's `ROW_COUNT`.

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

## Greenplum

The same deploy file is used on Greenplum 7. Greenplum has no `MERGE`. The suite was run on PostgreSQL 15.4. A Greenplum cluster was not started here.
