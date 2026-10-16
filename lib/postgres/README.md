# PostgreSQL and Greenplum

[Deploy](deploy.md) into a schema and put that schema on `search_path`. Methods and parameters: [root README](../../README.md). From SQL, call the functions with `select`. From PL/pgSQL, use `perform`.

Without batches, one refresh reads `dwa_keys_tmp`. The table holds only the current run. With batches, each refresh reads `dwa_batch_tmp`. `MERGE` needs PostgreSQL 15+. Greenplum has no `MERGE`: use `UPDATE` then `INSERT`.

```sql
do $run$
declare
    v_change_date timestamp := clock_timestamp();
begin
    perform initialize('customer_metrics', 'all');

    perform capture_delta('customers', $sql$
        select id::text as pk_1,
               updated_at as watermark
        from customers
        where updated_at > :since
    $sql$);

    perform capture_delta('orders', $sql$
        select customer_id::text as pk_1,
               max(updated_at) as watermark
        from orders
        where updated_at > :since
        group by customer_id
    $sql$);

    perform capture_delta('order_items', $sql$
        with changed_items as (
            select order_id, updated_at
            from order_items
            where updated_at > :since
        )
        select o.customer_id::text as pk_1,
               max(ci.updated_at) as watermark
        from changed_items ci
        join orders o on o.id = ci.order_id
        group by o.customer_id
    $sql$);

    perform prepare_batches(5000);

    while next_batch() loop
        merge into customer_metrics t
        using (
            with changed as (
                select pk_1::integer as customer_id
                from dwa_batch_tmp
                group by pk_1
            ),
            order_amount as (
                select c.id as customer_id,
                       o.id as order_id,
                       o.order_date,
                       o.status,
                       round(oi.quantity * oi.price * (1 - o.order_discount), 2) as amount
                from customers c
                join changed ch on ch.customer_id = c.id
                join orders o on o.customer_id = c.id
                join order_items oi on oi.order_id = o.id
            )
            select customer_id,
                   min(amount) as min_amount,
                   max(amount) as max_amount,
                   round(avg(amount), 2) as avg_amount,
                   (array_agg(order_id order by order_date desc, order_id desc))[1] as last_order_id,
                   count(*) filter (where status = 'completed') as cnt_completed
            from order_amount
            group by customer_id
        ) s
        on t.customer_id = s.customer_id
        when matched and (
            case when t.min_amount is not distinct from s.min_amount then 0 else 1 end
            + case when t.max_amount is not distinct from s.max_amount then 0 else 1 end
            + case when t.avg_amount is not distinct from s.avg_amount then 0 else 1 end
            + case when t.last_order_id is not distinct from s.last_order_id then 0 else 1 end
            + case when t.cnt_completed is not distinct from s.cnt_completed then 0 else 1 end
        ) > 0 then update set
            min_amount     = s.min_amount,
            max_amount     = s.max_amount,
            avg_amount     = s.avg_amount,
            last_order_id  = s.last_order_id,
            cnt_completed  = s.cnt_completed,
            mt_change_date = v_change_date
        when not matched then insert (
            customer_id, min_amount, max_amount, avg_amount,
            last_order_id, cnt_completed, mt_change_date
        ) values (
            s.customer_id, s.min_amount, s.max_amount, s.avg_amount,
            s.last_order_id, s.cnt_completed, v_change_date
        );

        perform finish_batch();
    end loop;

    perform finalize();
end;
$run$;
```

The same script is `demo/postgres/run.sql`. See [`demo/README.md`](../../demo/README.md).

The functions do not commit. Commit after each `finish_batch` and after `finalize`. A rollback of `initialize` drops the session temp tables. The run lock is session-scoped and survives that rollback until `finalize` or disconnect.

On Greenplum 7 the same [deploy](deploy.md) is used. Pass `p_merged` to `finish_batch` when the log should show the refresh row count.
