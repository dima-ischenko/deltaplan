-- Load of customer_metrics for metrics_* cases.
-- p_batch_size null = one statement on dwa_keys_tmp.
-- A positive size uses prepare_batches / dwa_batch_tmp.

drop table if exists customer_metrics_inc;

create table customer_metrics_inc (
    customer_id   integer primary key,
    min_amount    numeric,
    max_amount    numeric,
    avg_amount    numeric,
    last_order_id integer,
    cnt_completed numeric
);

create or replace procedure dwa_test.seed_customer_metrics()
language plpgsql as $$
begin
    delete from order_items;
    delete from orders;
    delete from customers;
    delete from customer_metrics;
    delete from dwa_watermark
    where target_table = 'customer_metrics';

    insert into customers (id, name, region, updated_at) values
        (1, 'anna', 'north', timestamp '2024-01-15 10:00:00'),
        (2, 'ben', 'south', timestamp '2024-01-15 10:00:00'),
        (3, 'cara', 'east', timestamp '2024-01-15 10:00:00');

    insert into orders (id, customer_id, order_date, status, order_discount, updated_at) values
        (101, 1, date '2024-01-10', 'completed', 0, timestamp '2024-01-15 10:00:01'),
        (102, 1, date '2024-01-12', 'completed', 0.1, timestamp '2024-01-15 10:00:01'),
        (201, 2, date '2024-01-11', 'new', 0, timestamp '2024-01-15 10:00:01'),
        (301, 3, date '2024-01-13', 'completed', 0, timestamp '2024-01-15 10:00:01');

    insert into order_items (order_id, product_id, quantity, price, updated_at) values
        (101, 1, 1, 10, timestamp '2024-01-15 10:00:02'),
        (101, 2, 2, 20, timestamp '2024-01-15 10:00:02'),
        (102, 1, 1, 50, timestamp '2024-01-15 10:00:02'),
        (201, 1, 1, 100, timestamp '2024-01-15 10:00:02'),
        (301, 1, 3, 7, timestamp '2024-01-15 10:00:02');
end;
$$;

create or replace procedure dwa_test.seed_customer_delta()
language plpgsql as $$
declare
    l_as_of        timestamp := clock_timestamp();
    l_wm           timestamp;
    l_customer_id  integer;
    l_max_customer integer;
    l_max_order    integer;
begin
    select max(watermark)
    into l_wm
    from dwa_watermark
    where target_table = 'customer_metrics'
      and data_slice = 'all';

    if l_wm is not null and l_as_of <= l_wm then
        l_as_of := l_wm + interval '1 second';
    end if;

    select min(id) into l_customer_id from customers;
    select max(id) into l_max_customer from customers;
    select max(id) into l_max_order from orders;

    update customers
    set name = name || '-u',
        updated_at = l_as_of
    where id = l_customer_id;

    update orders
    set status = case status
                     when 'completed' then 'cancelled'
                     when 'cancelled' then 'completed'
                     else 'completed'
                 end,
        order_discount = least(order_discount + 0.05, 0.5),
        updated_at = l_as_of
    where customer_id = l_customer_id;

    update order_items
    set price = round(price + 1, 2),
        updated_at = l_as_of
    where order_id in (
        select id from orders where customer_id = l_customer_id
    );

    insert into customers (id, name, region, updated_at)
    values (
        l_max_customer + 1,
        'customer-' || (l_max_customer + 1),
        'west',
        l_as_of
    );

    insert into orders (id, customer_id, order_date, status, order_discount, updated_at)
    values (
        l_max_order + 1,
        l_max_customer + 1,
        l_as_of::date,
        'completed',
        0,
        l_as_of
    );

    insert into order_items (order_id, product_id, quantity, price, updated_at)
    values (l_max_order + 1, 1, 2, 25.50, l_as_of);
end;
$$;

create or replace procedure dwa_test.run_customer_metrics(p_batch_size integer default null)
language plpgsql
set search_path = pg_temp, lib, public as $$
declare
    v_change_date timestamp := clock_timestamp();
begin
    perform initialize('customer_metrics', 'all');

    perform capture_delta(
        'customers',
        $sql$
            select id::text as pk_1,
                   updated_at as watermark
            from customers
            where updated_at > :since
        $sql$
    );
    perform capture_delta(
        'orders',
        $sql$
            select customer_id::text as pk_1,
                   max(updated_at) as watermark
            from orders
            where updated_at > :since
            group by customer_id
        $sql$
    );
    perform capture_delta(
        'order_items',
        $sql$
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

    if p_batch_size is null then
        merge into customer_metrics t
        using (
            with changed as (
                select pk_1::integer as customer_id
                from dwa_keys_tmp
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

        perform finalize();
    else
        perform prepare_batches(p_batch_size);

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
    end if;
end;
$$;

create or replace procedure dwa_test.run_incremental_passes(p_batch_size integer default null)
language plpgsql as $$
begin
    call dwa_test.run_customer_metrics(p_batch_size);
    call dwa_test.run_customer_metrics(p_batch_size);
    call dwa_test.seed_customer_delta();
    call dwa_test.run_customer_metrics(p_batch_size);
    call dwa_test.seed_customer_delta();
    call dwa_test.run_customer_metrics(p_batch_size);
end;
$$;

create or replace procedure dwa_test.snapshot_customer_metrics(p_reset boolean default false)
language plpgsql as $$
begin
    delete from customer_metrics_inc;
    insert into customer_metrics_inc (
        customer_id, min_amount, max_amount, avg_amount, last_order_id, cnt_completed
    )
    select customer_id, min_amount, max_amount, avg_amount, last_order_id, cnt_completed
    from customer_metrics;

    if p_reset then
        delete from customer_metrics;
        delete from dwa_watermark
        where target_table = 'customer_metrics';
    end if;
end;
$$;

create or replace function dwa_test.customer_metrics_xor()
returns integer
language sql stable as $$
    select count(*)::integer
    from (
        (select customer_id, min_amount, max_amount, avg_amount, last_order_id, cnt_completed
         from customer_metrics
         except
         select customer_id, min_amount, max_amount, avg_amount, last_order_id, cnt_completed
         from customer_metrics_inc)
        union all
        (select customer_id, min_amount, max_amount, avg_amount, last_order_id, cnt_completed
         from customer_metrics_inc
         except
         select customer_id, min_amount, max_amount, avg_amount, last_order_id, cnt_completed
         from customer_metrics)
    ) d;
$$;
