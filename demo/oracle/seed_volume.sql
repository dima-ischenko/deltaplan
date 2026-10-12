-- Large source for run.sql. Edit the three constants, then run tables.sql first.
--
-- Default: 100,000 customers, 1,000,000 orders, 30 items each.
-- Smaller smoke: 1000 / 10000 / 30.
--
-- Source rows keep the base timestamp. The watermark is the load time, which
-- is later than every base row, so the two-hour lookback in run.sql does not
-- recapture them. Plant the delta with seed_delta.sql.

set serveroutput on size unlimited
set timing on

declare
    c_customers       constant number := 100000;
    c_orders          constant number := 1000000;
    c_items_per_order constant number := 30;
    c_base_updated_at constant date := timestamp '2024-01-15 10:00:00';
    c_order_chunk     constant number := 50000;

    l_started   timestamp := systimestamp;
    l_per_cust  number;
    l_loaded    date;
    l_from      number;
    l_chunk     number;
    l_rows      number;
    l_expected  number;
    l_step      number;
    l_steps     number;

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
            || ' seed_volume: '
            || rpad(p_rows, 16) || '| '
            || p_text
            || ' ' || round(l_sec, 1) || 's'
        );
    end i_log;

    procedure drop_extra_indexes is
    begin
        for r in (
            select index_name
            from user_indexes
            where table_name in ('CUSTOMERS', 'ORDERS', 'ORDER_ITEMS')
              and index_name in (
                    'IX_CUSTOMERS_UPDATED',
                    'IX_ORDERS_CUSTOMER',
                    'IX_ORDERS_UPDATED',
                    'IX_ORDER_ITEMS_UPDATED'
                  )
        ) loop
            execute immediate 'drop index ' || r.index_name;
        end loop;
    end drop_extra_indexes;
begin
    if c_customers < 1 or c_orders < 1 or c_items_per_order < 1
       or c_customers != trunc(c_customers)
       or c_orders != trunc(c_orders)
       or c_items_per_order != trunc(c_items_per_order) then
        raise_application_error(-20020, 'volume counts must be positive integers');
    end if;

    if mod(c_orders, c_customers) != 0 then
        raise_application_error(-20020, 'c_orders must divide evenly by c_customers');
    end if;

    l_per_cust := c_orders / c_customers;

    drop_extra_indexes;

    execute immediate 'truncate table order_items';
    execute immediate 'truncate table orders';
    execute immediate 'truncate table customers';
    execute immediate 'truncate table customer_metrics';

    execute immediate 'alter table customers nologging';
    execute immediate 'alter table orders nologging';
    execute immediate 'alter table order_items nologging';

    i_log(
        'loading customers=' || c_customers
        || ' orders=' || c_orders
        || ' items_per_order=' || c_items_per_order,
        c_customers
    );

    insert into customers (id, name, region, updated_at)
    select n,
           'customer-' || n,
           case mod(n, 4)
               when 0 then 'north'
               when 1 then 'south'
               when 2 then 'east'
               else 'west'
           end,
           c_base_updated_at
    from (
        select level as n
        from dual
        connect by level <= c_customers
    );

    i_log('customers loaded', sql%rowcount);

    l_from := 1;
    while l_from <= c_orders loop
        l_chunk := least(c_order_chunk, c_orders - l_from + 1);

        insert into orders (id, customer_id, order_date, status, order_discount, updated_at)
        select l_from + level - 1,
               trunc((l_from + level - 2) / l_per_cust) + 1,
               date '2023-01-01' + mod(l_from + level, 400),
               case mod(l_from + level, 5)
                   when 0 then 'new'
                   when 1 then 'cancelled'
                   else 'completed'
               end,
               case when mod(l_from + level, 10) = 0 then 0.1 else 0 end,
               c_base_updated_at
        from dual
        connect by level <= l_chunk;

        commit;
        l_from := l_from + l_chunk;
    end loop;

    i_log('orders loaded', c_orders);

    l_from := 1;
    l_step := 0;
    l_steps := ceil(c_orders / c_order_chunk);
    while l_from <= c_orders loop
        l_step := l_step + 1;
        l_chunk := least(c_order_chunk, c_orders - l_from + 1);
        l_expected := l_chunk * c_items_per_order;

        insert /*+ append */ into order_items (order_id, product_id, quantity, price, updated_at)
        select o.order_id,
               p.product_id,
               1 + mod(o.order_id + p.product_id, 5),
               round(50 + mod(o.order_id * 7 + p.product_id * 11, 50000) / 100, 2),
               c_base_updated_at
        from (
            select l_from + level - 1 as order_id
            from dual
            connect by level <= l_chunk
        ) o
        cross join (
            select level as product_id
            from dual
            connect by level <= c_items_per_order
        ) p;

        l_rows := sql%rowcount;
        if l_rows != l_expected then
            raise_application_error(-20022, 'order_items chunk loaded ' || l_rows || ', expected ' || l_expected);
        end if;

        commit;

        i_log(
            'order_items chunk ' || l_step || '/' || l_steps
            || ' orders=' || l_from || '..' || (l_from + l_chunk - 1),
            l_rows
        );

        l_from := l_from + l_chunk;
    end loop;

    execute immediate 'alter table customers logging';
    execute immediate 'alter table orders logging';
    execute immediate 'alter table order_items logging';

    l_loaded := sysdate;

    delete from dpl_watermark
    where target_table = 'customer_metrics'
      and data_segment = 'all';

    insert into dpl_watermark (target_table, data_segment, source_table, watermark, updated_at)
    select 'customer_metrics', 'all', column_value, l_loaded, l_loaded
    from table(sys.odcivarchar2list('customers', 'orders', 'order_items'));

    commit;

    i_log(
        'watermark=' || to_char(l_loaded, 'yyyy-mm-dd hh24:mi:ss')
        || ' base=' || to_char(c_base_updated_at, 'yyyy-mm-dd hh24:mi:ss'),
        3
    );

    i_log('done loading, restoring indexes', c_orders * c_items_per_order);
end;
/

@demo/oracle/indexes.sql

begin
    dbms_stats.gather_table_stats(user, 'CUSTOMERS', estimate_percent => 1, cascade => true);
    dbms_stats.gather_table_stats(user, 'ORDERS', estimate_percent => 1, cascade => true);
    dbms_stats.gather_table_stats(user, 'ORDER_ITEMS', estimate_percent => 1, cascade => true);
    dbms_stats.gather_table_stats(user, 'CUSTOMER_METRICS', estimate_percent => 100, cascade => true);
    dbms_output.put_line(to_char(systimestamp, 'hh24:mi:ss.ff3') || ' seed_volume: stats gathered, next: @demo/oracle/seed_delta.sql');
exception
    when others then
        dbms_output.put_line(to_char(systimestamp, 'hh24:mi:ss.ff3') || ' seed_volume: stats skipped ' || sqlerrm);
end;
/
