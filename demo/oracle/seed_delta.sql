-- Delta on top of seed_volume.sql. Does not truncate or reload the base.
--
-- Default: 7% of the customers already loaded. Half of that slice is updated,
-- half is inserted as new customers with the same orders-per-customer shape.
-- Run it again to plant another slice. The watermark is left where seed_volume
-- or the last run.sql put it, so the next run.sql captures every source row
-- whose updated_at is still above that watermark.

set serveroutput on size unlimited
set timing on

declare
    c_delta_pct   constant number := 7;
    c_order_chunk constant number := 50000;

    l_started          timestamp := systimestamp;
    l_customers        number;
    l_orders           number;
    l_items            number;
    l_per_cust         number;
    l_items_per_order  number;
    l_touch            number;
    l_upd              number;
    l_new              number;
    l_wm_cnt           number;
    l_wm               date;
    l_max_updated      date;
    l_as_of            date;
    l_max_customer     number;
    l_max_order        number;
    l_from             number;
    l_chunk            number;

    procedure i_log(p_text varchar2, p_rows number default 0) is
        l_delta interval day to second := systimestamp - l_started;
        l_sec   number;
    begin
        l_sec := extract(day from l_delta) * 86400
               + extract(hour from l_delta) * 3600
               + extract(minute from l_delta) * 60
               + extract(second from l_delta);
        dbms_output.put_line(
            to_char(systimestamp, 'hh24:mi:ss.ff3')
            || ' seed_delta: '
            || rpad(p_rows, 16) || '| '
            || p_text
            || ' ' || round(l_sec, 1) || 's'
        );
    end i_log;
begin
    if c_delta_pct <= 0 or c_delta_pct != trunc(c_delta_pct) then
        raise_application_error(-20021, 'c_delta_pct must be a positive integer');
    end if;

    select count(*) into l_customers from customers;
    select count(*) into l_orders from orders;
    select count(*) into l_items from order_items;

    if l_customers < 1 or l_orders < 1 or l_items < 1 then
        raise_application_error(-20023, 'source tables are empty; run seed_volume.sql first');
    end if;

    if mod(l_orders, l_customers) != 0 or mod(l_items, l_orders) != 0 then
        raise_application_error(-20023, 'seed_delta expects the even volume from seed_volume.sql');
    end if;

    l_per_cust := l_orders / l_customers;
    l_items_per_order := l_items / l_orders;
    l_touch := round(l_customers * c_delta_pct / 100);
    l_upd := trunc(l_touch / 2);
    l_new := l_touch - l_upd;

    if l_upd < 1 or l_new < 1 then
        raise_application_error(-20021, 'delta is too small; load more customers or raise c_delta_pct');
    end if;

    select count(*), max(watermark)
    into l_wm_cnt, l_wm
    from dpl_watermark
    where target_table = 'customer_metrics'
      and data_segment = 'all'
      and source_table in ('customers', 'orders', 'order_items');

    if l_wm_cnt != 3 then
        raise_application_error(
            -20024,
            'customer_metrics watermarks=' || l_wm_cnt || '; run seed_volume.sql first'
        );
    end if;

    select max(updated_at)
    into l_max_updated
    from (
        select max(updated_at) as updated_at from customers
        union all
        select max(updated_at) from orders
        union all
        select max(updated_at) from order_items
    );

    l_as_of := sysdate;
    if l_as_of <= l_wm or l_as_of <= l_max_updated then
        l_as_of := greatest(l_wm, l_max_updated) + 1 / 86400;
    end if;

    select max(id) into l_max_customer from customers;
    select max(id) into l_max_order from orders;

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
    select l_max_customer + n,
           'customer-' || (l_max_customer + n),
           case mod(n, 4)
               when 0 then 'north'
               when 1 then 'south'
               when 2 then 'east'
               else 'west'
           end,
           l_as_of
    from (
        select level as n
        from dual
        connect by level <= l_new
    );

    l_from := 1;
    while l_from <= l_new * l_per_cust loop
        l_chunk := least(c_order_chunk, l_new * l_per_cust - l_from + 1);

        insert into orders (id, customer_id, order_date, status, order_discount, updated_at)
        select l_max_order + l_from + level - 1,
               l_max_customer + trunc((l_from + level - 2) / l_per_cust) + 1,
               trunc(l_as_of) - mod(level, 30),
               case mod(level, 5)
                   when 0 then 'new'
                   when 1 then 'cancelled'
                   else 'completed'
               end,
               case when mod(level, 10) = 0 then 0.1 else 0 end,
               l_as_of
        from dual
        connect by level <= l_chunk;

        commit;
        l_from := l_from + l_chunk;
    end loop;

    l_from := 1;
    while l_from <= l_new * l_per_cust loop
        l_chunk := least(c_order_chunk, l_new * l_per_cust - l_from + 1);

        insert into order_items (order_id, product_id, quantity, price, updated_at)
        select o.order_id,
               p.product_id,
               1 + mod(o.order_id + p.product_id, 5),
               round(50 + mod(o.order_id * 7 + p.product_id * 11, 50000) / 100, 2),
               l_as_of
        from (
            select l_max_order + l_from + level - 1 as order_id
            from dual
            connect by level <= l_chunk
        ) o
        cross join (
            select level as product_id
            from dual
            connect by level <= l_items_per_order
        ) p;

        commit;
        l_from := l_from + l_chunk;
    end loop;

    commit;

    i_log(
        'updated_customers=' || l_upd
        || ' new_customers=' || l_new
        || ' as_of=' || to_char(l_as_of, 'yyyy-mm-dd hh24:mi:ss')
        || ' watermark=' || to_char(l_wm, 'yyyy-mm-dd hh24:mi:ss'),
        l_touch
    );
end;
/

begin
    dbms_stats.gather_table_stats(user, 'CUSTOMERS', estimate_percent => 1, cascade => true);
    dbms_stats.gather_table_stats(user, 'ORDERS', estimate_percent => 1, cascade => true);
    dbms_stats.gather_table_stats(user, 'ORDER_ITEMS', estimate_percent => 1, cascade => true);
    dbms_output.put_line(to_char(systimestamp, 'hh24:mi:ss.ff3') || ' seed_delta: stats gathered, next: @demo/oracle/run.sql');
exception
    when others then
        dbms_output.put_line(to_char(systimestamp, 'hh24:mi:ss.ff3') || ' seed_delta: stats skipped ' || sqlerrm);
end;
/
