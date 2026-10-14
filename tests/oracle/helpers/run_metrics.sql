-- Load of customer_metrics for metrics_* cases.
-- p_batch_size null = one statement on dpl_keys_tmp.
-- A positive size uses prepare_batches / dpl_batch_tmp.

begin
    execute immediate 'drop table customer_metrics_inc purge';
exception
    when others then
        if sqlcode != -942 then
            raise;
        end if;
end;
/

create table customer_metrics_inc (
    customer_id   number not null,
    min_amount    number(10, 2),
    max_amount    number(10, 2),
    avg_amount    number(10, 2),
    last_order_id number,
    cnt_completed number,
    constraint pk_customer_metrics_inc primary key (customer_id)
);

create or replace procedure seed_customer_metrics is
begin
    delete from order_items;
    delete from orders;
    delete from customers;
    delete from customer_metrics;
    delete from dpl_watermark
    where target_table = 'customer_metrics';

    insert into customers (id, name, region, updated_at) values
        (1, 'anna', 'north', timestamp '2024-01-15 10:00:00');
    insert into customers (id, name, region, updated_at) values
        (2, 'ben', 'south', timestamp '2024-01-15 10:00:00');
    insert into customers (id, name, region, updated_at) values
        (3, 'cara', 'east', timestamp '2024-01-15 10:00:00');

    insert into orders (id, customer_id, order_date, status, order_discount, updated_at) values
        (101, 1, date '2024-01-10', 'completed', 0, timestamp '2024-01-15 10:00:01');
    insert into orders (id, customer_id, order_date, status, order_discount, updated_at) values
        (102, 1, date '2024-01-12', 'completed', 0.1, timestamp '2024-01-15 10:00:01');
    insert into orders (id, customer_id, order_date, status, order_discount, updated_at) values
        (201, 2, date '2024-01-11', 'new', 0, timestamp '2024-01-15 10:00:01');
    insert into orders (id, customer_id, order_date, status, order_discount, updated_at) values
        (301, 3, date '2024-01-13', 'completed', 0, timestamp '2024-01-15 10:00:01');

    insert into order_items (order_id, product_id, quantity, price, updated_at) values
        (101, 1, 1, 10, timestamp '2024-01-15 10:00:02');
    insert into order_items (order_id, product_id, quantity, price, updated_at) values
        (101, 2, 2, 20, timestamp '2024-01-15 10:00:02');
    insert into order_items (order_id, product_id, quantity, price, updated_at) values
        (102, 1, 1, 50, timestamp '2024-01-15 10:00:02');
    insert into order_items (order_id, product_id, quantity, price, updated_at) values
        (201, 1, 1, 100, timestamp '2024-01-15 10:00:02');
    insert into order_items (order_id, product_id, quantity, price, updated_at) values
        (301, 1, 3, 7, timestamp '2024-01-15 10:00:02');

    commit;
end seed_customer_metrics;
/

create or replace procedure seed_customer_delta is
    l_as_of        date := sysdate;
    l_wm           date;
    l_customer_id  number;
    l_max_customer number;
    l_max_order    number;
begin
    select max(watermark)
    into l_wm
    from dpl_watermark
    where target_table = 'customer_metrics'
      and data_segment = 'all';

    if l_wm is not null and l_as_of <= l_wm then
        l_as_of := l_wm + 1 / 86400;
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
        trunc(l_as_of),
        'completed',
        0,
        l_as_of
    );

    insert into order_items (order_id, product_id, quantity, price, updated_at)
    values (l_max_order + 1, 1, 2, 25.50, l_as_of);

    commit;
end seed_customer_delta;
/

create or replace procedure run_customer_metrics(p_batch_size number default null) is
    l_change_date date := sysdate;

    procedure capture_all is
    begin
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
    end capture_all;

    procedure merge_keys is
    begin
        merge into customer_metrics t
            using (
                with changed as (
                    select pk_1 as customer_id
                    from dpl_keys_tmp
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
    end merge_keys;

    procedure merge_batch is
    begin
        merge into customer_metrics t
            using (
                with changed as (
                    select pk_1 as customer_id
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
    end merge_batch;
begin
    pkg_dpl.initialize('customer_metrics', 'all');
    capture_all;

    if p_batch_size is null then
        merge_keys;
        pkg_dpl.finalize;
    else
        pkg_dpl.prepare_batches(p_batch_size);
        while pkg_dpl.next_batch loop
            merge_batch;
            pkg_dpl.finish_batch;
        end loop;
        pkg_dpl.finalize;
    end if;

    commit;
end run_customer_metrics;
/

create or replace procedure run_incremental_passes(p_batch_size number default null) is
begin
    run_customer_metrics(p_batch_size);
    run_customer_metrics(p_batch_size);
    seed_customer_delta;
    run_customer_metrics(p_batch_size);
    seed_customer_delta;
    run_customer_metrics(p_batch_size);
end run_incremental_passes;
/

create or replace procedure snapshot_customer_metrics(p_reset boolean default false) is
begin
    delete from customer_metrics_inc;
    insert into customer_metrics_inc (
        customer_id, min_amount, max_amount, avg_amount, last_order_id, cnt_completed
    )
    select customer_id, min_amount, max_amount, avg_amount, last_order_id, cnt_completed
    from customer_metrics;

    if p_reset then
        delete from customer_metrics;
        delete from dpl_watermark
        where target_table = 'customer_metrics';
    end if;

    commit;
end snapshot_customer_metrics;
/

create or replace function customer_metrics_xor return number is
    l_diff number;
begin
    select count(*)
    into l_diff
    from (
        (select customer_id, min_amount, max_amount, avg_amount, last_order_id, cnt_completed
         from customer_metrics
         minus
         select customer_id, min_amount, max_amount, avg_amount, last_order_id, cnt_completed
         from customer_metrics_inc)
        union all
        (select customer_id, min_amount, max_amount, avg_amount, last_order_id, cnt_completed
         from customer_metrics_inc
         minus
         select customer_id, min_amount, max_amount, avg_amount, last_order_id, cnt_completed
         from customer_metrics)
    );

    return l_diff;
end customer_metrics_xor;
/
