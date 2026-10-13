-- Delta on top of seed_volume.sql. Does not truncate or reload the base.
--
-- Default: 7% of the customers already loaded. c_delta_mode is update
-- (only updates), insert (only new customers), or mix (half of each).
-- Run it again to plant another slice. This script does not touch
-- dpl_watermark. If run.sql has already stored one, planted rows get a
-- timestamp after it so the next run.sql captures them.

\timing on
\set ON_ERROR_STOP on

do $seed$
declare
    c_delta_pct integer := 7;
    -- update | insert | mix
    c_delta_mode text := 'update';

    l_mode            text;
    l_started         timestamptz := clock_timestamp();
    l_customers       integer;
    l_orders          integer;
    l_items           integer;
    l_per_cust        integer;
    l_items_per_order integer;
    l_touch           integer;
    l_upd             integer;
    l_new             integer;
    l_wm              timestamp;
    l_max_updated     timestamp;
    l_as_of           timestamp;
    l_max_customer    integer;
    l_max_order       integer;
    l_elapsed         numeric;
begin
    l_mode := lower(trim(c_delta_mode));
    if l_mode not in ('update', 'insert', 'mix') then
        raise exception 'c_delta_mode must be update, insert, or mix';
    end if;

    if c_delta_pct < 1 then
        raise exception 'c_delta_pct must be a positive integer';
    end if;

    select count(*) into l_customers from customers;
    select count(*) into l_orders from orders;
    select count(*) into l_items from order_items;

    if l_customers < 1 or l_orders < 1 or l_items < 1 then
        raise exception 'source tables are empty; run seed_volume.sql first';
    end if;

    if l_orders % l_customers <> 0 or l_items % l_orders <> 0 then
        raise exception 'seed_delta expects the even volume from seed_volume.sql';
    end if;

    l_per_cust := l_orders / l_customers;
    l_items_per_order := l_items / l_orders;
    l_touch := round(l_customers * c_delta_pct / 100.0);
    if l_mode = 'update' then
        l_upd := l_touch;
        l_new := 0;
    elsif l_mode = 'insert' then
        l_upd := 0;
        l_new := l_touch;
    else
        l_upd := l_touch / 2;
        l_new := l_touch - l_upd;
    end if;

    if l_touch < 1 or (l_mode = 'mix' and (l_upd < 1 or l_new < 1)) then
        raise exception 'delta is too small; load more customers or raise c_delta_pct';
    end if;

    select max(watermark)
    into l_wm
    from dpl_watermark
    where target_table = 'customer_metrics'
      and data_segment = 'all'
      and source_table in ('customers', 'orders', 'order_items');

    select max(updated_at)
    into l_max_updated
    from (
        select max(updated_at) as updated_at from customers
        union all
        select max(updated_at) from orders
        union all
        select max(updated_at) from order_items
    ) src;

    l_as_of := clock_timestamp();
    if l_wm is not null and l_as_of <= l_wm then
        l_as_of := l_wm + interval '1 second';
    end if;
    if l_as_of <= l_max_updated then
        l_as_of := l_max_updated + interval '1 second';
    end if;

    select max(id) into l_max_customer from customers;
    select max(id) into l_max_order from orders;

    if l_upd > 0 then
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
    end if;

    if l_new > 0 then
        insert into customers (id, name, region, updated_at)
        select l_max_customer + n,
               'customer-' || (l_max_customer + n),
               case n % 4
                   when 0 then 'north'
                   when 1 then 'south'
                   when 2 then 'east'
                   else 'west'
               end,
               l_as_of
        from generate_series(1, l_new) n;

        insert into orders (id, customer_id, order_date, status, order_discount, updated_at)
        select l_max_order + n,
               l_max_customer + ((n - 1) / l_per_cust) + 1,
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
        from generate_series(l_max_order + 1, l_max_order + l_new * l_per_cust) as o(order_id)
        cross join generate_series(1, l_items_per_order) as p(product_id);
    end if;

    l_elapsed := round(extract(epoch from clock_timestamp() - l_started)::numeric, 1);
    raise notice 'seed_delta: % | mode=% updated_customers=% new_customers=% as_of=% watermark=% %s',
        rpad(l_touch::text, 16), l_mode, l_upd, l_new, l_as_of, l_wm, l_elapsed;
end;
$seed$;

analyze customers;
analyze orders;
analyze order_items;
