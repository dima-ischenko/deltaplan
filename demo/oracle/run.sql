-- Incremental load of customer_metrics.
-- Capture keys that moved, refresh those keys in batches, then move the watermark.
-- pkg_dpl prints a timing line for each step. set timing on adds the wall time
-- of the whole block.

set serveroutput on size unlimited
set timing on

declare
    l_change_date date := sysdate;
begin
    pkg_dpl.initialize(
        p_target_table   => 'customer_metrics',
        p_data_segment   => 'all',
        p_lookback_hours => 2
    );

    pkg_dpl.capture_delta(
        p_source_table => 'customers',
        p_sql => q'[
            select id as pk_1,
                   updated_at as watermark
            from customers
            where updated_at > :since
        ]'
    );

    pkg_dpl.capture_delta(
        p_source_table => 'orders',
        p_sql => q'[
            select customer_id as pk_1,
                   max(updated_at) as watermark
            from orders
            where updated_at > :since
            group by customer_id
        ]'
    );

    pkg_dpl.capture_delta(
        p_source_table => 'order_items',
        p_sql => q'[
            with changed_items as (
                select order_id, updated_at
                from order_items
                where updated_at > :since
            )
            select o.customer_id as pk_1,
                   max(ci.updated_at) as watermark
            from changed_items ci
            join orders o on o.id = ci.order_id
            group by o.customer_id
        ]'
    );

    pkg_dpl.prepare_batches(p_batch_size => 5000);

    while pkg_dpl.next_batch loop
        merge into customer_metrics t
            using (
                with changed as (
                    select /*+ dynamic_sampling(dpl_batch_tmp 4) */
                           pk_1 as customer_id
                    from dpl_batch_tmp
                    group by pk_1
                )
                select c.id as customer_id,
                       min(oi.quantity * oi.price * (1 - o.order_discount)) as min_amount,
                       max(oi.quantity * oi.price * (1 - o.order_discount)) as max_amount,
                       avg(oi.quantity * oi.price * (1 - o.order_discount)) as avg_amount,
                       max(o.id) keep (dense_rank last order by o.order_date) as last_order_id,
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
                t.last_order_id  = s.last_order_id,
                t.cnt_completed  = s.cnt_completed,
                t.mt_change_date = l_change_date
            when not matched then insert (
                customer_id, min_amount, max_amount, avg_amount,
                last_order_id, cnt_completed, mt_change_date
            ) values (
                s.customer_id, s.min_amount, s.max_amount, s.avg_amount,
                s.last_order_id, s.cnt_completed, l_change_date
            );

        pkg_dpl.finish_batch;
    end loop;

    pkg_dpl.finalize;
    commit;
end;
/
