-- The same shape as examples/oracle/example_customer_metrics.sql.
-- This file is an illustration. It expects customers, orders, order_items
-- and customer_metrics to exist already, and it is not part of the test run.
--
-- The load is UPDATE plus INSERT. That runs on PostgreSQL 11+ and on
-- Greenplum 7, which has no MERGE. On PostgreSQL 15+ the same logic can
-- be written as one MERGE.
--
-- :since is the capture placeholder. capture_delta binds it.
-- Without batches, read deltaplan_keys and call deltaplan.finalize() at once:
--   where k.target_table = deltaplan.get_target_table()
--     and k.data_segment = deltaplan.get_data_segment()
-- PostgreSQL has no packages. next_batch() is a function; the rest are procedures.

call deltaplan.initialize('customer_metrics', 'all', 2);

call deltaplan.capture_delta('customers', $sql$
    select id as pk_1,
           null::text as pk_2,
           null::text as pk_3,
           updated_at as watermark
    from customers
    where updated_at > :since
$sql$);

call deltaplan.capture_delta('orders', $sql$
    select o.customer_id as pk_1,
           null::text as pk_2,
           null::text as pk_3,
           max(o.updated_at) as watermark
    from orders o
    where o.updated_at > :since
    group by o.customer_id
$sql$);

call deltaplan.prepare_batches(2);

while deltaplan.next_batch() loop
    update customer_metrics t
    set min_amount = s.min_amount,
        max_amount = s.max_amount,
        avg_amount = s.avg_amount,
        cnt_completed = s.cnt_completed,
        mt_change_date = clock_timestamp()
    from (
        select c.id as customer_id,
               min(oi.quantity * oi.price * (1 - o.order_discount)) as min_amount,
               max(oi.quantity * oi.price * (1 - o.order_discount)) as max_amount,
               avg(oi.quantity * oi.price * (1 - o.order_discount)) as avg_amount,
               count(case when o.status = 'completed' then 1 end) as cnt_completed
        from customers c
        join deltaplan_batch w on w.pk_1 = c.id
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
        select c.id as customer_id,
               min(oi.quantity * oi.price * (1 - o.order_discount)) as min_amount,
               max(oi.quantity * oi.price * (1 - o.order_discount)) as max_amount,
               avg(oi.quantity * oi.price * (1 - o.order_discount)) as avg_amount,
               count(case when o.status = 'completed' then 1 end) as cnt_completed
        from customers c
        join deltaplan_batch w on w.pk_1 = c.id
        join orders o on o.customer_id = c.id
        join order_items oi on oi.order_id = o.id
        group by c.id
    ) s
    where not exists (
        select 1 from customer_metrics t where t.customer_id = s.customer_id
    );

    call deltaplan.finish_batch();
end loop;

call deltaplan.finalize();
