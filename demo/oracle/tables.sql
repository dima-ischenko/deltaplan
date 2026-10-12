-- Source tables and the target. Run this once, then seed.sql or seed_volume.sql.
begin execute immediate 'drop table demo_numbers purge'; exception when others then if sqlcode != -942 then raise; end if; end;
/
begin execute immediate 'drop table demo_seed_state purge'; exception when others then if sqlcode != -942 then raise; end if; end;
/
begin execute immediate 'drop table order_items purge'; exception when others then if sqlcode != -942 then raise; end if; end;
/
begin execute immediate 'drop table orders purge'; exception when others then if sqlcode != -942 then raise; end if; end;
/
begin execute immediate 'drop table customers purge'; exception when others then if sqlcode != -942 then raise; end if; end;
/
begin execute immediate 'drop table customer_metrics purge'; exception when others then if sqlcode != -942 then raise; end if; end;
/

create table customers (
    id         number not null,
    name       varchar2(100) not null,
    region     varchar2(50) not null,
    updated_at date not null,
    constraint pk_customers primary key (id)
);

create table orders (
    id             number not null,
    customer_id    number not null,
    order_date     date not null,
    status         varchar2(20) not null,
    order_discount number not null,
    updated_at     date not null,
    constraint pk_orders primary key (id),
    constraint ck_orders_status check (status in ('new', 'completed', 'cancelled'))
);

create table order_items (
    order_id   number not null,
    product_id number not null,
    quantity   number not null,
    price      number(10, 2) not null,
    updated_at date not null,
    constraint pk_order_items primary key (order_id, product_id)
);

create table customer_metrics (
    customer_id    number not null,
    min_amount     number(10, 2),
    max_amount     number(10, 2),
    avg_amount     number(10, 2),
    last_order_id  number,
    cnt_completed  number,
    mt_change_date date,
    constraint pk_customer_metrics primary key (customer_id)
);

@@indexes.sql
