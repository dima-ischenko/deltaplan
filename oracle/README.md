# Oracle

Deploy and rollback: [deploy.md](deploy.md).

The package keeps its position in the session, so a rollback does not forget which batch was open. When `p_commit` is true, which is the default, the captured keys are committed first and each `finish_batch` commits its own batch. A later call in the same session resumes at the unfinished batch. After a rollback `deltaplan_batch_tmp` is empty, and the next `next_batch` returns that same batch. The `finish_batch` log line records `sql%rowcount` of the preceding statement.

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
