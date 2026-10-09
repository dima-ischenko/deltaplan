create or replace package body pkg_deltaplan_demo is

    c_target          constant varchar2(128) := 'customer_metrics';
    c_segment         constant varchar2(64) := 'all';
    c_base_updated_at constant date := timestamp '2024-01-15 10:00:00';
    c_order_chunk     constant number := 50000;
    c_number_chunk    constant number := 100000;

    gv_output_ready boolean := false;

    procedure i_log(p_proc_name varchar2,
                    p_rows      number,
                    p_text      varchar2 default null) is
    begin
        if not gv_output_ready then
            dbms_output.enable(buffer_size => null);
            gv_output_ready := true;
        end if;

        dbms_output.put_line(
            to_char(systimestamp, 'hh24:mi:ss.ff3') || ' '
            || p_proc_name || ': '
            || rpad(p_rows, 16) || '|'
            || p_text
        );
    end i_log;

    function seconds_since(p_from timestamp) return number is
        l_delta interval day to second := systimestamp - p_from;
    begin
        return extract(day from l_delta) * 86400
             + extract(hour from l_delta) * 3600
             + extract(minute from l_delta) * 60
             + extract(second from l_delta);
    end seconds_since;

    procedure drop_table(p_name varchar2) is
    begin
        execute immediate 'drop table ' || p_name || ' purge';
    exception
        when others then
            if sqlcode != -942 then
                raise;
            end if;
    end drop_table;

    procedure exec_ignore_missing(p_sql varchar2) is
    begin
        execute immediate p_sql;
    exception
        when others then
            if sqlcode != -942 then
                raise;
            end if;
    end exec_ignore_missing;

    procedure create_tables is
    begin
        drop_table('order_items');
        drop_table('orders');
        drop_table('customers');
        drop_table('customer_metrics');
        drop_table('demo_numbers');
        drop_table('demo_seed_state');

        execute immediate '
            create table demo_numbers (
                n number not null,
                constraint pk_demo_numbers primary key (n)
            )';

        execute immediate '
            create table customers (
                id         number not null,
                name       varchar2(100) not null,
                region     varchar2(50) not null,
                updated_at date not null
            ) nologging';

        execute immediate '
            create table orders (
                id             number not null,
                customer_id    number not null,
                order_date     date not null,
                status         varchar2(20) not null,
                order_discount number not null,
                updated_at     date not null,
                constraint ck_orders_status check (status in (''new'', ''completed'', ''cancelled''))
            ) nologging';

        execute immediate '
            create table order_items (
                order_id   number not null,
                product_id number not null,
                quantity   number not null,
                price      number(10,2) not null,
                updated_at date not null
            ) nologging';

        execute immediate '
            create table customer_metrics (
                customer_id    number not null,
                min_amount     number(10,2),
                max_amount     number(10,2),
                avg_amount     number(10,2),
                last_order_id  number,
                cnt_completed  number,
                updated_at date,
                constraint pk_customer_metrics primary key (customer_id)
            )';

        execute immediate '
            create table demo_seed_state (
                id                     number not null,
                customers              number not null,
                orders                 number not null,
                items_per_order        number not null,
                base_updated_at        date not null,
                waves                  number default 0 not null,
                last_delta_at          date,
                last_updated_customers number,
                last_new_customers     number,
                constraint pk_demo_seed_state primary key (id),
                constraint ck_demo_seed_state_id check (id = 1)
            )';
    end create_tables;

    procedure build_numbers(p_rows number) is
        l_from  number := 1;
        l_chunk number;
    begin
        while l_from <= p_rows loop
            l_chunk := least(c_number_chunk, p_rows - l_from + 1);

            insert into demo_numbers (n)
            select l_from + level - 1
            from dual
            connect by level <= l_chunk;

            commit;
            l_from := l_from + l_chunk;
        end loop;
    end build_numbers;

    procedure load_customers(p_customers number) is
    begin
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
        from demo_numbers
        where n <= p_customers;

        if sql%rowcount != p_customers then
            raise_application_error(-20022, 'customers loaded ' || sql%rowcount || ', expected ' || p_customers);
        end if;

        commit;
    end load_customers;

    procedure load_orders(p_orders number, p_orders_per_customer number) is
        l_from  number := 1;
        l_chunk number;
        l_rows  number;
    begin
        while l_from <= p_orders loop
            l_chunk := least(c_order_chunk, p_orders - l_from + 1);

            insert into orders (id, customer_id, order_date, status, order_discount, updated_at)
            select l_from + d.n - 1,
                   trunc((l_from + d.n - 2) / p_orders_per_customer) + 1,
                   date '2023-01-01' + mod(l_from + d.n, 400),
                   case mod(l_from + d.n, 5)
                       when 0 then 'new'
                       when 1 then 'cancelled'
                       else 'completed'
                   end,
                   case when mod(l_from + d.n, 10) = 0 then 0.1 else 0 end,
                   c_base_updated_at
            from (
                select n
                from demo_numbers
                where n <= l_chunk
            ) d;

            l_rows := sql%rowcount;
            if l_rows != l_chunk then
                raise_application_error(-20022, 'orders chunk loaded ' || l_rows || ', expected ' || l_chunk);
            end if;

            commit;
            l_from := l_from + l_chunk;
        end loop;
    end load_orders;

    procedure load_items(p_orders number, p_items_per_order number) is
        l_proc_name varchar2(64) := 'pkg_deltaplan_demo.load_base';
        l_from      number := 1;
        l_chunk     number;
        l_rows      number;
        l_expected  number;
        l_step      number := 0;
        l_steps     number := ceil(p_orders / c_order_chunk);
        l_started   timestamp;
    begin
        while l_from <= p_orders loop
            l_step := l_step + 1;
            l_chunk := least(c_order_chunk, p_orders - l_from + 1);
            l_expected := l_chunk * p_items_per_order;
            l_started := systimestamp;

            insert /*+ append */ into order_items (order_id, product_id, quantity, price, updated_at)
            select o.order_id,
                   p.product_id,
                   1 + mod(o.order_id + p.product_id, 5),
                   round(50 + mod(o.order_id * 7 + p.product_id * 11, 50000) / 100, 2),
                   c_base_updated_at
            from (
                select l_from + n - 1 as order_id
                from demo_numbers
                where n <= l_chunk
            ) o
            cross join (
                select n as product_id
                from demo_numbers
                where n <= p_items_per_order
            ) p;

            l_rows := sql%rowcount;
            if l_rows != l_expected then
                raise_application_error(-20022, 'order_items chunk loaded ' || l_rows || ', expected ' || l_expected);
            end if;

            commit;

            i_log(
                l_proc_name,
                l_rows,
                'order_items chunk ' || l_step || '/' || l_steps
                || ' orders=' || l_from || '..' || (l_from + l_chunk - 1)
                || ' ' || round(seconds_since(l_started), 1) || 's'
            );

            l_from := l_from + l_chunk;
        end loop;
    end load_items;

    procedure create_indexes(p_proc_name varchar2) is
        l_started timestamp := systimestamp;
    begin
        execute immediate 'create unique index pk_customers on customers (id) nologging';
        execute immediate 'alter table customers add constraint pk_customers primary key (id) using index pk_customers';

        execute immediate 'create unique index pk_orders on orders (id) nologging';
        execute immediate 'alter table orders add constraint pk_orders primary key (id) using index pk_orders';
        execute immediate 'create index ix_orders_customer on orders (customer_id) nologging';
        execute immediate 'create index ix_orders_updated on orders (updated_at) nologging';

        execute immediate 'create unique index pk_order_items on order_items (order_id, product_id) nologging';
        execute immediate 'alter table order_items add constraint pk_order_items primary key (order_id, product_id) using index pk_order_items';
        execute immediate 'create index ix_order_items_updated on order_items (updated_at) nologging';

        execute immediate 'create index ix_customers_updated on customers (updated_at) nologging';

        execute immediate 'alter table customers logging';
        execute immediate 'alter table orders logging';
        execute immediate 'alter table order_items logging';

        i_log(p_proc_name, 0, 'indexes ' || round(seconds_since(l_started), 1) || 's');
    end create_indexes;

    procedure mark_synced(p_watermark date) is
    begin
        for src in (
            select 'customers' as source_table from dual
            union all
            select 'orders' from dual
            union all
            select 'order_items' from dual
        ) loop
            merge into deltaplan_watermark t
            using (
                select c_target as target_table,
                       c_segment as data_segment,
                       src.source_table as source_table,
                       p_watermark as watermark
                from dual
            ) s
            on (t.target_table = s.target_table
                and t.data_segment = s.data_segment
                and t.source_table = s.source_table)
            when matched then
                update set t.watermark = s.watermark,
                           t.updated_at = sysdate
            when not matched then
                insert (target_table, data_segment, source_table, watermark, updated_at)
                values (s.target_table, s.data_segment, s.source_table, s.watermark, sysdate);
        end loop;
    end mark_synced;

    procedure gather_stats(p_proc_name varchar2) is
        l_started timestamp := systimestamp;
    begin
        dbms_stats.gather_table_stats(user, 'CUSTOMERS', estimate_percent => 1, cascade => true);
        dbms_stats.gather_table_stats(user, 'ORDERS', estimate_percent => 1, cascade => true);
        dbms_stats.gather_table_stats(user, 'ORDER_ITEMS', estimate_percent => 1, cascade => true);
        dbms_stats.gather_table_stats(user, 'CUSTOMER_METRICS', estimate_percent => 100, cascade => true);
        i_log(p_proc_name, 0, 'stats ' || round(seconds_since(l_started), 1) || 's');
    exception
        when others then
            i_log(p_proc_name, 0, 'stats skipped ' || sqlerrm);
    end gather_stats;

    procedure load_base(
        p_customers       number  default 100000,
        p_orders          number  default 1000000,
        p_items_per_order number  default 30,
        p_mark_synced     boolean default true
    ) is
        l_proc_name varchar2(64) := 'pkg_deltaplan_demo.load_base';
        l_started   timestamp := systimestamp;
        l_per_cust  number;
        l_items     number;
        l_cnt       number;
        l_sync      boolean := true;
    begin
        if p_mark_synced = false then
            l_sync := false;
        end if;

        if p_customers is null or p_customers < 1 or p_customers != trunc(p_customers) then
            raise_application_error(-20020, 'p_customers must be a positive integer');
        end if;

        if p_orders is null or p_orders < 1 or p_orders != trunc(p_orders) then
            raise_application_error(-20020, 'p_orders must be a positive integer');
        end if;

        if p_items_per_order is null or p_items_per_order < 1 or p_items_per_order != trunc(p_items_per_order) then
            raise_application_error(-20020, 'p_items_per_order must be a positive integer');
        end if;

        if mod(p_orders, p_customers) != 0 then
            raise_application_error(-20020, 'p_orders must divide evenly by p_customers');
        end if;

        l_per_cust := p_orders / p_customers;
        l_items := p_orders * p_items_per_order;

        if l_sync then
            begin
                execute immediate 'select 1 from deltaplan_watermark where 1 = 0';
            exception
                when others then
                    if sqlcode = -942 then
                        raise_application_error(
                            -20025,
                            'deltaplan_watermark does not exist. Install it or call load_base(p_mark_synced => false)'
                        );
                    end if;
                    raise;
            end;
        end if;

        begin
            create_tables;
            build_numbers(greatest(p_customers, c_order_chunk, p_items_per_order));

            i_log(l_proc_name, p_customers, 'loading customers, ' || l_per_cust || ' orders each, ' || p_items_per_order || ' items each');
            load_customers(p_customers);

            i_log(l_proc_name, p_orders, 'loading orders');
            load_orders(p_orders, l_per_cust);

            i_log(l_proc_name, l_items, 'loading order_items');
            load_items(p_orders, p_items_per_order);

            select count(*) into l_cnt from order_items;
            if l_cnt != l_items then
                raise_application_error(-20022, 'order_items count ' || l_cnt || ', expected ' || l_items);
            end if;

            create_indexes(l_proc_name);

            insert into demo_seed_state (
                id, customers, orders, items_per_order, base_updated_at, waves
            ) values (
                1, p_customers, p_orders, p_items_per_order, c_base_updated_at, 0
            );

            exec_ignore_missing('delete from deltaplan_keys_tmp where target_table = ''' || c_target || ''' and data_segment = ''' || c_segment || '''');
            exec_ignore_missing('delete from deltaplan_batch_tmp');

            if l_sync then
                mark_synced(c_base_updated_at);
                i_log(
                    l_proc_name,
                    3,
                    'watermark=' || to_char(c_base_updated_at, 'yyyy-mm-dd hh24:mi:ss')
                    || ' sources=customers,orders,order_items target=' || c_target
                );
            end if;

            commit;
            gather_stats(l_proc_name);

            i_log(
                l_proc_name,
                l_items,
                'done customers=' || p_customers
                || ' orders=' || p_orders
                || ' order_items=' || l_items
                || ' ' || round(seconds_since(l_started), 1) || 's'
            );
        exception
            when others then
                i_log(l_proc_name, 0, 'failed ' || sqlerrm || ', rerun load_base');
                rollback;
                raise;
        end;
    end load_base;

    procedure read_state(
        p_customers       out number,
        p_orders          out number,
        p_items_per_order out number,
        p_base_updated_at out date,
        p_waves           out number
    ) is
    begin
        select customers, orders, items_per_order, base_updated_at, waves
        into p_customers, p_orders, p_items_per_order, p_base_updated_at, p_waves
        from demo_seed_state
        where id = 1;
    exception
        when no_data_found then
            raise_application_error(-20021, 'Call load_base first');
    end read_state;

    procedure touch_range(
        p_cust_from      number,
        p_cust_to        number,
        p_orders_per_cust number,
        p_as_of          date,
        p_wave           number,
        p_customers      out number,
        p_orders         out number,
        p_items          out number
    ) is
        l_ord_from number := (p_cust_from - 1) * p_orders_per_cust + 1;
        l_ord_to   number := p_cust_to * p_orders_per_cust;
    begin
        update customers
        set name = 'customer-' || id || '-u' || p_wave,
            region = case region
                         when 'north' then 'south'
                         when 'south' then 'east'
                         when 'east' then 'west'
                         else 'north'
                     end,
            updated_at = p_as_of
        where id between p_cust_from and p_cust_to;
        p_customers := sql%rowcount;

        update orders
        set status = case status
                         when 'completed' then 'cancelled'
                         when 'cancelled' then 'completed'
                         else 'completed'
                     end,
            order_discount = least(order_discount + 0.05, 0.5),
            updated_at = p_as_of
        where id between l_ord_from and l_ord_to;
        p_orders := sql%rowcount;

        update order_items
        set price = round(price + 1, 2),
            updated_at = p_as_of
        where order_id between l_ord_from and l_ord_to;
        p_items := sql%rowcount;
    end touch_range;

    procedure plant_delta(
        p_delta_pct    number default 7,
        p_update_share number default 0.5,
        p_as_of        date   default null
    ) is
        l_proc_name   varchar2(64) := 'pkg_deltaplan_demo.plant_delta';
        l_started     timestamp := systimestamp;
        l_base_cust   number;
        l_base_orders number;
        l_items_each  number;
        l_base_ts     date;
        l_waves       number;
        l_per_cust    number;
        l_touch       number;
        l_upd         number;
        l_new         number;
        l_wave        number;
        l_as_of       date;
        l_max_ts      date;
        l_max_cust    number;
        l_max_order   number;
        l_cust_cnt    number;
        l_ord_cnt     number;
        l_from        number;
        l_head        number;
        l_ranges      varchar2(128);
        l_upd_cust    number := 0;
        l_upd_orders  number := 0;
        l_upd_items   number := 0;
        l_rows        number;
        l_ord_rows    number;
        l_item_rows   number;
        l_new_cust_from number;
        l_new_ord_from  number;
        l_pos         number;
        l_chunk       number;
        l_new_orders  number;
        l_cust_part   number;
        l_ord_part    number;
        l_item_part   number;
    begin
        if p_delta_pct is null or p_delta_pct < 5 or p_delta_pct > 10 then
            raise_application_error(-20020, 'p_delta_pct must be between 5 and 10');
        end if;

        if p_update_share is null or p_update_share <= 0 or p_update_share >= 1 then
            raise_application_error(-20020, 'p_update_share must be greater than 0 and less than 1');
        end if;

        read_state(l_base_cust, l_base_orders, l_items_each, l_base_ts, l_waves);
        l_per_cust := l_base_orders / l_base_cust;
        l_touch := round(l_base_cust * p_delta_pct / 100);
        l_upd := round(l_touch * p_update_share);
        l_new := l_touch - l_upd;

        if l_upd < 1 or l_new < 1 then
            raise_application_error(-20021, 'delta is too small to include both updates and new rows');
        end if;

        if l_upd > l_base_cust then
            raise_application_error(-20021, 'update slice is larger than the base customers');
        end if;

        select count(*), max(id) into l_cust_cnt, l_max_cust from customers;
        select count(*), max(id) into l_ord_cnt, l_max_order from orders;

        if l_cust_cnt != l_max_cust or l_ord_cnt != l_max_order or l_max_order != l_max_cust * l_per_cust then
            raise_application_error(
                -20024,
                'id alignment broken, customers=' || l_cust_cnt
                || ' max_customer=' || l_max_cust
                || ' orders=' || l_ord_cnt
                || ' max_order=' || l_max_order
            );
        end if;

        select greatest(
                   (select max(updated_at) from customers),
                   (select max(updated_at) from orders),
                   (select max(updated_at) from order_items)
               )
        into l_max_ts
        from dual;

        l_as_of := p_as_of;
        if l_as_of is null then
            l_as_of := sysdate;
        end if;

        if l_as_of <= l_max_ts then
            l_as_of := l_max_ts + 1 / 86400;
        end if;

        l_wave := l_waves + 1;
        l_from := 1 + mod((l_wave - 1) * l_upd, l_base_cust);

        if l_from + l_upd - 1 <= l_base_cust then
            touch_range(l_from, l_from + l_upd - 1, l_per_cust, l_as_of, l_wave, l_cust_part, l_ord_part, l_item_part);
            l_upd_cust := l_cust_part;
            l_upd_orders := l_ord_part;
            l_upd_items := l_item_part;
            l_ranges := l_from || '..' || (l_from + l_upd - 1);
        else
            l_head := l_upd - (l_base_cust - l_from + 1);
            touch_range(l_from, l_base_cust, l_per_cust, l_as_of, l_wave, l_cust_part, l_ord_part, l_item_part);
            l_upd_cust := l_cust_part;
            l_upd_orders := l_ord_part;
            l_upd_items := l_item_part;
            touch_range(1, l_head, l_per_cust, l_as_of, l_wave, l_cust_part, l_ord_part, l_item_part);
            l_upd_cust := l_upd_cust + l_cust_part;
            l_upd_orders := l_upd_orders + l_ord_part;
            l_upd_items := l_upd_items + l_item_part;
            l_ranges := l_from || '..' || l_base_cust || ',1..' || l_head;
        end if;

        if l_upd_cust != l_upd
           or l_upd_orders != l_upd * l_per_cust
           or l_upd_items != l_upd_orders * l_items_each then
            raise_application_error(
                -20023,
                'updated customers=' || l_upd_cust
                || ' orders=' || l_upd_orders
                || ' items=' || l_upd_items
                || ', expected customers=' || l_upd
            );
        end if;

        l_new_cust_from := l_max_cust + 1;
        l_new_ord_from := l_max_order + 1;
        l_new_orders := l_new * l_per_cust;

        insert into customers (id, name, region, updated_at)
        select l_new_cust_from + n - 1,
               'customer-' || (l_new_cust_from + n - 1),
               case mod(n, 4)
                   when 0 then 'north'
                   when 1 then 'south'
                   when 2 then 'east'
                   else 'west'
               end,
               l_as_of
        from demo_numbers
        where n <= l_new;

        if sql%rowcount != l_new then
            raise_application_error(-20023, 'inserted customers ' || sql%rowcount || ', expected ' || l_new);
        end if;

        l_pos := 0;
        while l_pos < l_new_orders loop
            l_chunk := least(c_order_chunk, l_new_orders - l_pos);

            insert into orders (id, customer_id, order_date, status, order_discount, updated_at)
            select l_new_ord_from + l_pos + d.n - 1,
                   l_new_cust_from + trunc((l_pos + d.n - 1) / l_per_cust),
                   trunc(l_as_of) - mod(d.n, 30),
                   case mod(d.n, 5)
                       when 0 then 'new'
                       when 1 then 'cancelled'
                       else 'completed'
                   end,
                   case when mod(d.n, 10) = 0 then 0.1 else 0 end,
                   l_as_of
            from (
                select n
                from demo_numbers
                where n <= l_chunk
            ) d;

            l_rows := sql%rowcount;
            if l_rows != l_chunk then
                raise_application_error(-20023, 'inserted orders chunk ' || l_rows || ', expected ' || l_chunk);
            end if;

            l_pos := l_pos + l_chunk;
        end loop;

        l_pos := 0;
        l_item_rows := 0;
        while l_pos < l_new_orders loop
            l_chunk := least(c_order_chunk, l_new_orders - l_pos);

            insert into order_items (order_id, product_id, quantity, price, updated_at)
            select o.order_id,
                   p.product_id,
                   1 + mod(o.order_id + p.product_id, 5),
                   round(50 + mod(o.order_id * 7 + p.product_id * 11, 50000) / 100, 2),
                   l_as_of
            from (
                select l_new_ord_from + l_pos + n - 1 as order_id
                from demo_numbers
                where n <= l_chunk
            ) o
            cross join (
                select n as product_id
                from demo_numbers
                where n <= l_items_each
            ) p;

            l_rows := sql%rowcount;
            if l_rows != l_chunk * l_items_each then
                raise_application_error(-20023, 'inserted items chunk ' || l_rows || ', expected ' || (l_chunk * l_items_each));
            end if;

            l_item_rows := l_item_rows + l_rows;
            l_pos := l_pos + l_chunk;
        end loop;

        l_ord_rows := l_new_orders;

        update demo_seed_state
        set waves = l_wave,
            last_delta_at = l_as_of,
            last_updated_customers = l_upd,
            last_new_customers = l_new
        where id = 1;

        commit;

        i_log(
            l_proc_name,
            l_upd_cust,
            'updated customers=' || l_upd_cust
            || ' orders=' || l_upd_orders
            || ' items=' || l_upd_items
            || ' customer_ids=' || l_ranges
        );
        i_log(
            l_proc_name,
            l_new,
            'inserted customers=' || l_new
            || ' orders=' || l_ord_rows
            || ' items=' || l_item_rows
            || ' customer_ids=' || l_new_cust_from || '..' || (l_new_cust_from + l_new - 1)
        );
        i_log(
            l_proc_name,
            l_touch,
            'delta_pct=' || p_delta_pct
            || ' update_share=' || p_update_share
            || ' customers=' || round(100 * l_touch / l_base_cust, 2)
            || '% orders=' || round(100 * (l_upd_orders + l_ord_rows) / l_base_orders, 2)
            || '% items=' || round(100 * (l_upd_items + l_item_rows) / (l_base_orders * l_items_each), 2)
            || '% as_of=' || to_char(l_as_of, 'yyyy-mm-dd hh24:mi:ss')
            || ' wave=' || l_wave
            || ' ' || round(seconds_since(l_started), 1) || 's'
        );

        gather_stats(l_proc_name);
    exception
        when others then
            i_log(l_proc_name, 0, 'failed ' || sqlerrm);
            rollback;
            raise;
    end plant_delta;

    procedure report is
        l_proc_name varchar2(64) := 'pkg_deltaplan_demo.report';
        l_base_cust number;
        l_base_orders number;
        l_items_each number;
        l_base_ts date;
        l_waves number;
        l_cust_cnt number;
        l_ord_cnt number;
        l_max_cust number;
        l_max_order number;
        l_per_cust number;
        l_last_at date;
        l_last_upd number;
        l_last_new number;
    begin
        read_state(l_base_cust, l_base_orders, l_items_each, l_base_ts, l_waves);

        select last_delta_at, last_updated_customers, last_new_customers
        into l_last_at, l_last_upd, l_last_new
        from demo_seed_state
        where id = 1;

        select count(*), max(id) into l_cust_cnt, l_max_cust from customers;
        select count(*), max(id) into l_ord_cnt, l_max_order from orders;
        l_per_cust := l_base_orders / l_base_cust;

        i_log(
            l_proc_name,
            l_cust_cnt,
            'customers=' || l_cust_cnt
            || ' orders=' || l_ord_cnt
            || ' order_items=' || (l_ord_cnt * l_items_each)
            || ' base_customers=' || l_base_cust
            || ' waves=' || l_waves
            || ' base_updated_at=' || to_char(l_base_ts, 'yyyy-mm-dd hh24:mi:ss')
            || ' last_delta_at=' || nvl(to_char(l_last_at, 'yyyy-mm-dd hh24:mi:ss'), 'null')
            || ' last_updated=' || nvl(to_char(l_last_upd), '0')
            || ' last_new=' || nvl(to_char(l_last_new), '0')
            || ' aligned=' || case
                   when l_cust_cnt = l_max_cust
                    and l_ord_cnt = l_max_order
                    and l_max_order = l_max_cust * l_per_cust
                   then 'yes' else 'no' end
        );
    end report;

end pkg_deltaplan_demo;
