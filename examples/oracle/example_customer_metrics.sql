-- A short run: a lookback of two hours, and a target merge in batches of two keys.
-- The merge is ordinary SQL against deltaplan_batch_tmp.
-- Without batches the same merge reads deltaplan_keys_tmp and the loop is omitted:
--   where target_table = pkg_deltaplan.get_target_table
--     and data_segment = pkg_deltaplan.get_data_segment
-- then call finalize at once.
-- set serveroutput on size unlimited

begin
    pkg_deltaplan.initialize(
        p_target_table   => 'customer_metrics',
        p_data_segment   => 'all',
        p_lookback_hours => 2
    );

    pkg_deltaplan.capture_delta(
        p_source_table => 'customers',
        p_sql => q'[
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
        ]'
    );

    pkg_deltaplan.capture_delta(
        p_source_table => 'orders',
        p_sql => q'[
            with changed_orders as (
                select customer_id, updated_at
                from orders
                where updated_at > :since
            )
            select customer_id as pk_1,
                   null as pk_2,
                   null as pk_3,
                   max(updated_at) as watermark
            from changed_orders
            group by customer_id
        ]'
    );

    pkg_deltaplan.capture_delta(
        p_source_table => 'order_items',
        p_sql => q'[
            with changed_items as (
                select order_id, updated_at
                from order_items
                where updated_at > :since
            )
            select o.customer_id as pk_1,
                   null as pk_2,
                   null as pk_3,
                   max(ci.updated_at) as watermark
            from changed_items ci
            join orders o on o.id = ci.order_id
            group by o.customer_id
        ]'
    );

    pkg_deltaplan.prepare_batches(p_batch_size => 2);

    while pkg_deltaplan.next_batch loop
        merge into customer_metrics t
            using (
                with changed_customers as (
                    select pk_1 as customer_id
                    from deltaplan_batch_tmp
                    group by pk_1
                )
                select c.id as customer_id,
                       min(oi.quantity * oi.price * (1 - o.order_discount)) as min_amount,
                       max(oi.quantity * oi.price * (1 - o.order_discount)) as max_amount,
                       avg(oi.quantity * oi.price * (1 - o.order_discount)) as avg_amount,
                       max(o.id) keep (dense_rank last order by o.order_date) as last_order_id,
                       count(case when o.status = 'completed' then 1 end) as cnt_completed
                from customers c
                join changed_customers wcc on wcc.customer_id = c.id
                join orders o on o.customer_id = c.id
                join order_items oi on oi.order_id = o.id
                group by c.id
            ) s
            on (s.customer_id = t.customer_id)
            when matched then update
                set t.min_amount = s.min_amount,
                    t.max_amount = s.max_amount,
                    t.avg_amount = s.avg_amount,
                    t.last_order_id = s.last_order_id,
                    t.cnt_completed = s.cnt_completed,
                    t.mt_change_date = sysdate
                where decode(t.min_amount, s.min_amount, 0, 1)
                    + decode(t.max_amount, s.max_amount, 0, 1)
                    + decode(t.avg_amount, s.avg_amount, 0, 1)
                    + decode(t.last_order_id, s.last_order_id, 0, 1)
                    + decode(t.cnt_completed, s.cnt_completed, 0, 1) > 0
            when not matched then insert (
                customer_id, min_amount, max_amount, avg_amount,
                last_order_id, cnt_completed, mt_change_date
            ) values (
                s.customer_id, s.min_amount, s.max_amount, s.avg_amount,
                s.last_order_id, s.cnt_completed, sysdate
            );

        pkg_deltaplan.finish_batch;
    end loop;

    pkg_deltaplan.finalize;
    commit;
end;
/
