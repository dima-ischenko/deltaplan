-- Large source for run.sql. Edit the three constants, then run tables.sql first.
--
-- Default: 100,000 customers, 1,000,000 orders, 30 items each.
-- Smaller smoke: 1000 / 10000 / 30.
--
-- Source rows keep a fixed base timestamp. This script does not touch
-- dpl_watermark; run.sql writes it after computing customer_metrics.
-- Plant a later slice with seed_delta.sql.

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
    c_base_updated_at timestamp := timestamp '2024-01-15 10:00:00';
    c_order_chunk     integer := 50000;

    l_started   timestamptz := clock_timestamp();
    l_per_cust  integer;
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
           c_base_updated_at + interval '1 second'
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
               c_base_updated_at + interval '2 seconds'
        from generate_series(l_from, l_from + l_chunk - 1) as o(order_id)
        cross join generate_series(1, c_items_per_order) as p(product_id);

        get diagnostics l_rows = row_count;
        l_elapsed := round(extract(epoch from clock_timestamp() - l_started)::numeric, 1);
        raise notice 'seed_volume: % | order_items chunk %/% orders=%..% %s',
            rpad(l_rows::text, 16), l_step, l_steps, l_from, l_from + l_chunk - 1, l_elapsed;

        l_from := l_from + l_chunk;
    end loop;

    l_elapsed := round(extract(epoch from clock_timestamp() - l_started)::numeric, 1);
    raise notice 'seed_volume: % | base=% %s',
        rpad((c_orders * c_items_per_order)::text, 16), c_base_updated_at, l_elapsed;
    raise notice 'seed_volume: % | done, restoring indexes %s',
        rpad((c_orders * c_items_per_order)::text, 16), l_elapsed;
end;
$seed$;

\i demo/postgres/indexes.sql

analyze customers;
analyze orders;
analyze order_items;
analyze customer_metrics;
