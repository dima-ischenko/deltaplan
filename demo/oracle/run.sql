-- Incremental load of customer_metrics.
-- Capture keys that moved, refresh those keys in batches, then move the watermark.
-- pkg_dwa prints a timing line for each step. set timing on adds the wall time
-- of the whole block.

set serveroutput on size unlimited
set timing on

declare
    l_change_date date := sysdate;
begin
    pkg_dwa.initialize(
        p_target_table => 'customer_metrics',
        p_data_slice => 'all'
    );

    pkg_dwa.capture_delta(
        p_source_table => 'customers',
        p_sql => q'[
            select id as pk_1,
                   updated_at as watermark
            from customers
            where updated_at > :since
        ]'
    );

    pkg_dwa.capture_delta(
        p_source_table => 'orders',
        p_sql => q'[
            select customer_id as pk_1,
                   max(updated_at) as watermark
            from orders
            where updated_at > :since
            group by customer_id
        ]'
    );

    pkg_dwa.capture_delta(
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

    pkg_dwa.prepare_batches(p_batch_size => 5000);

    while pkg_dwa.next_batch loop
        merge into customer_metrics t
            using (
                with changed as (
                    select /*+ dynamic_sampling(dwa_batch_tmp 4) */
                           pk_1 as customer_id
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
                       max(order_id) keep (dense_rank last order by order_date) as last_order_id,
                       count(case when status = 'completed' then 1 end) as cnt_completed
                from order_amount
                group by customer_id
            ) s
            on (s.customer_id = t.customer_id)
            when matched then update set
                t.min_amount     = s.min_amount,
                t.max_amount     = s.max_amount,
                t.avg_amount     = s.avg_amount,
                t.last_order_id  = s.last_order_id,
                t.cnt_completed  = s.cnt_completed,
                t.mt_change_date = l_change_date
            where (decode(t.min_amount, s.min_amount, 0, 1) +
                   decode(t.max_amount, s.max_amount, 0, 1) +
                   decode(t.avg_amount, s.avg_amount, 0, 1) +
                   decode(t.last_order_id, s.last_order_id, 0, 1) +
                   decode(t.cnt_completed, s.cnt_completed, 0, 1)
                  ) > 0
            when not matched then insert (
                customer_id, min_amount, max_amount, avg_amount,
                last_order_id, cnt_completed, mt_change_date
            ) values (
                s.customer_id, s.min_amount, s.max_amount, s.avg_amount,
                s.last_order_id, s.cnt_completed, l_change_date
            );

        pkg_dwa.finish_batch;
    end loop;

    pkg_dwa.finalize;
    commit;
end;
/
