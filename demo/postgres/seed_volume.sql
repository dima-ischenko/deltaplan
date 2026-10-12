-- Large source for run.sql. Edit the four constants, then run tables.sql first.
--
-- Default: 100,000 customers, 1,000,000 orders, 30 items each.
-- Smaller smoke: 1000 / 10000 / 30.
--
-- After the base load the base timestamp is written to dpl_watermark, then a
-- 7% delta is planted (half updates, half new customers). run.sql therefore
-- captures only that delta.

\timing on
\set ON_ERROR_STOP on

drop index if exists ix_customers_updated;
drop index if exists ix_orders_customer;
drop index if exists ix_orders_updated;
drop index if exists ix_order_items_updated;

truncate table order_items;
truncate table orders;
truncate table customers;
truncate table customer_metrics;

do $seed$
declare
    c_customers       integer := 100000;
    c_orders          integer := 1000000;
    c_items_per_order integer := 30;
    c_delta_pct       integer := 7;
    c_base_updated_at timestamp := timestamp '2024-01-15 10:00:00';
    c_order_chunk     integer := 50000;

    l_started   timestamptz := clock_timestamp();
    l_per_cust  integer;
    l_touch     integer;
    l_upd       integer;
    l_new       integer;
    l_as_of     timestamp;
    l_from      integer;
    l_chunk     integer;
    l_rows      integer;
    l_step      integer;
    l_steps     integer;
    l_elapsed   numeric;
begin
    if c_customers < 1 or c_orders < 1 or c_items_per_order < 1 then
        raise exception 'volume counts must be positive integers';
    end if;

    if c_orders % c_customers <> 0 then
        raise exception 'c_orders must divide evenly by c_customers';
    end if;

    l_per_cust := c_orders / c_customers;
    l_touch := round(c_customers * c_delta_pct / 100.0);
    l_upd := l_touch / 2;
    l_new := l_touch - l_upd;

    if l_upd < 1 or l_new < 1 then
        raise exception 'delta is too small; raise c_customers or c_delta_pct';
    end if;

    l_elapsed := round(extract(epoch from clock_timestamp() - l_started)::numeric, 1);
    raise notice 'seed_volume: % | loading customers=% orders=% items_per_order=% %s',
        rpad(c_customers::text, 16), c_customers, c_orders, c_items_per_order, l_elapsed;

    insert into customers (id, name, region, updated_at)
    select n,
           'customer-' || n,
           case n % 4
               when 0 then 'north'
               when 1 then 'south'
               when 2 then 'east'
               else 'west'
           end,
           c_base_updated_at
    from generate_series(1, c_customers) n;

    get diagnostics l_rows = row_count;
    l_elapsed := round(extract(epoch from clock_timestamp() - l_started)::numeric, 1);
    raise notice 'seed_volume: % | customers loaded %s', rpad(l_rows::text, 16), l_elapsed;

    insert into orders (id, customer_id, order_date, status, order_discount, updated_at)
    select n,
           ((n - 1) / l_per_cust) + 1,
           date '2023-01-01' + (n % 400),
           case n % 5
               when 0 then 'new'
               when 1 then 'cancelled'
               else 'completed'
           end,
           case when n % 10 = 0 then 0.1 else 0 end,
           c_base_updated_at
    from generate_series(1, c_orders) n;

    get diagnostics l_rows = row_count;
    l_elapsed := round(extract(epoch from clock_timestamp() - l_started)::numeric, 1);
    raise notice 'seed_volume: % | orders loaded %s', rpad(l_rows::text, 16), l_elapsed;

    l_from := 1;
    l_step := 0;
    l_steps := ceil(c_orders::numeric / c_order_chunk);
    while l_from <= c_orders loop
        l_step := l_step + 1;
        l_chunk := least(c_order_chunk, c_orders - l_from + 1);

        insert into order_items (order_id, product_id, quantity, price, updated_at)
        select o.order_id,
               p.product_id,
               1 + (o.order_id + p.product_id) % 5,
               round((50 + ((o.order_id * 7 + p.product_id * 11) % 50000) / 100.0)::numeric, 2),
               c_base_updated_at
        from generate_series(l_from, l_from + l_chunk - 1) as o(order_id)
        cross join generate_series(1, c_items_per_order) as p(product_id);

        get diagnostics l_rows = row_count;
        l_elapsed := round(extract(epoch from clock_timestamp() - l_started)::numeric, 1);
        raise notice 'seed_volume: % | order_items chunk %/% orders=%..% %s',
            rpad(l_rows::text, 16), l_step, l_steps, l_from, l_from + l_chunk - 1, l_elapsed;

        l_from := l_from + l_chunk;
    end loop;

    delete from dpl_watermark
    where target_table = 'customer_metrics'
      and data_segment = 'all';

    insert into dpl_watermark (target_table, data_segment, source_table, watermark, updated_at)
    values
        ('customer_metrics', 'all', 'customers', c_base_updated_at, clock_timestamp()),
        ('customer_metrics', 'all', 'orders', c_base_updated_at, clock_timestamp()),
        ('customer_metrics', 'all', 'order_items', c_base_updated_at, clock_timestamp());

    l_as_of := clock_timestamp();
    if l_as_of <= c_base_updated_at then
        l_as_of := c_base_updated_at + interval '1 second';
    end if;

    update customers
    set name = name || '-u',
        updated_at = l_as_of
    where id <= l_upd;

    update orders
    set status = case status
                     when 'completed' then 'cancelled'
                     when 'cancelled' then 'completed'
                     else 'completed'
                 end,
        order_discount = least(order_discount + 0.05, 0.5),
        updated_at = l_as_of
    where customer_id <= l_upd;

    update order_items
    set price = round(price + 1, 2),
        updated_at = l_as_of
    where order_id <= l_upd * l_per_cust;

    insert into customers (id, name, region, updated_at)
    select c_customers + n,
           'customer-' || (c_customers + n),
           case n % 4
               when 0 then 'north'
               when 1 then 'south'
               when 2 then 'east'
               else 'west'
           end,
           l_as_of
    from generate_series(1, l_new) n;

    insert into orders (id, customer_id, order_date, status, order_discount, updated_at)
    select c_orders + n,
           c_customers + ((n - 1) / l_per_cust) + 1,
           (l_as_of::date) - (n % 30),
           case n % 5
               when 0 then 'new'
               when 1 then 'cancelled'
               else 'completed'
           end,
           case when n % 10 = 0 then 0.1 else 0 end,
           l_as_of
    from generate_series(1, l_new * l_per_cust) n;

    insert into order_items (order_id, product_id, quantity, price, updated_at)
    select o.order_id,
           p.product_id,
           1 + (o.order_id + p.product_id) % 5,
           round((50 + ((o.order_id * 7 + p.product_id * 11) % 50000) / 100.0)::numeric, 2),
           l_as_of
    from generate_series(c_orders + 1, c_orders + l_new * l_per_cust) as o(order_id)
    cross join generate_series(1, c_items_per_order) as p(product_id);

    l_elapsed := round(extract(epoch from clock_timestamp() - l_started)::numeric, 1);
    raise notice 'seed_volume: % | delta updated_customers=% new_customers=% as_of=% %s',
        rpad(l_touch::text, 16), l_upd, l_new, l_as_of, l_elapsed;
end;
$seed$;

\ir indexes.sql

analyze customers;
analyze orders;
analyze order_items;
analyze customer_metrics;
