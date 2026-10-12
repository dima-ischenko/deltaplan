-- Incremental load of customer_metrics.
-- Capture keys that moved, refresh those keys in batches, then move the watermark.
-- dpl prints a notice for each step.
--
-- MERGE needs PostgreSQL 15+. Greenplum has no MERGE: use UPDATE then INSERT,
-- as in lib/postgres/README.md.

\timing on

do $run$
declare
    v_change_date timestamp := clock_timestamp();
begin
    perform initialize(
        p_target_table   => 'customer_metrics',
        p_data_segment   => 'all',
        p_lookback_hours => 2
    );

    perform capture_delta(
        p_source_table => 'customers',
        p_sql => $sql$
            select id::text as pk_1,
                   updated_at as watermark
            from customers
            where updated_at > :since
        $sql$
    );

    perform capture_delta(
        p_source_table => 'orders',
        p_sql => $sql$
            select customer_id::text as pk_1,
                   max(updated_at) as watermark
            from orders
            where updated_at > :since
            group by customer_id
        $sql$
    );

    perform capture_delta(
        p_source_table => 'order_items',
        p_sql => $sql$
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
        $sql$
    );

    perform prepare_batches(p_batch_size => 5000);

    while next_batch() loop
        merge into customer_metrics t
        using (
            with changed as (
                select pk_1::integer as customer_id
                from dpl_batch_tmp
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
