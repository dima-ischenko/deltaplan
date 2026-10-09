-- The same shape as examples/oracle/example_customer_metrics.sql.
-- This file is an illustration. It expects customers, orders, order_items
-- and customer_metrics to exist already, and it is not part of the test run.
--
-- Capture first isolates the changed rows, then joins. The load is UPDATE
-- plus INSERT. That runs on PostgreSQL and on Greenplum 7, which has no MERGE.
-- On PostgreSQL 15+ the same logic can be written as one MERGE.
--
-- The routines are functions and do not commit. Wrap the run in a DO block
-- so the batch loop can call them with PERFORM.
-- Without batches, read deltaplan_keys_tmp and call deltaplan.finalize() at once:
--   where k.target_table = deltaplan.get_target_table()
--     and k.data_segment = deltaplan.get_data_segment()

do $run$
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
               null::text as pk_2,
               null::text as pk_3,
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
               null::text as pk_2,
               null::text as pk_3,
               max(ci.updated_at) as watermark
        from changed_items ci
        join orders o on o.id = ci.order_id
        group by o.customer_id
    $sql$);

    perform deltaplan.prepare_batches(2);

    while deltaplan.next_batch() loop
        update customer_metrics t
        set min_amount = s.min_amount,
            max_amount = s.max_amount,
            avg_amount = s.avg_amount,
            cnt_completed = s.cnt_completed,
            mt_change_date = clock_timestamp()
        from (
            with changed_customers as (
                select pk_1 as customer_id
                from deltaplan_batch_tmp
                group by pk_1
            )
            select c.id as customer_id,
                   min(oi.quantity * oi.price * (1 - o.order_discount)) as min_amount,
                   max(oi.quantity * oi.price * (1 - o.order_discount)) as max_amount,
                   avg(oi.quantity * oi.price * (1 - o.order_discount)) as avg_amount,
                   count(case when o.status = 'completed' then 1 end) as cnt_completed
            from changed_customers wcc
            join customers c on c.id = wcc.customer_id
            join orders o on o.customer_id = c.id
            join order_items oi on oi.order_id = o.id
            group by c.id
        ) s
        where t.customer_id = s.customer_id;

        insert into customer_metrics (
            customer_id, min_amount, max_amount, avg_amount, cnt_completed, mt_change_date
        )
        select s.customer_id, s.min_amount, s.max_amount, s.avg_amount,
               s.cnt_completed, clock_timestamp()
        from (
            with changed_customers as (
                select pk_1 as customer_id
                from deltaplan_batch_tmp
                group by pk_1
            )
            select c.id as customer_id,
                   min(oi.quantity * oi.price * (1 - o.order_discount)) as min_amount,
                   max(oi.quantity * oi.price * (1 - o.order_discount)) as max_amount,
                   avg(oi.quantity * oi.price * (1 - o.order_discount)) as avg_amount,
                   count(case when o.status = 'completed' then 1 end) as cnt_completed
            from changed_customers wcc
            join customers c on c.id = wcc.customer_id
            join orders o on o.customer_id = c.id
            join order_items oi on oi.order_id = o.id
            group by c.id
        ) s
        where not exists (
            select 1 from customer_metrics t where t.customer_id = s.customer_id
        );

        perform deltaplan.finish_batch();
    end loop;

    perform deltaplan.finalize();
end;
$run$;
