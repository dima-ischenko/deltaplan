-- Tiny fixture for example_customer_metrics.sql. Three customers, four orders.
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

insert into customers (id, name, region, updated_at) values
    (1, 'anna', 'north', timestamp '2024-01-15 10:00:00');
insert into customers (id, name, region, updated_at) values
    (2, 'ben', 'south', timestamp '2024-01-15 10:00:00');
insert into customers (id, name, region, updated_at) values
    (3, 'cara', 'east', timestamp '2024-01-15 10:00:00');

insert into orders (id, customer_id, order_date, status, order_discount, updated_at) values
    (101, 1, date '2024-01-10', 'completed', 0, timestamp '2024-01-15 10:00:00');
insert into orders (id, customer_id, order_date, status, order_discount, updated_at) values
    (102, 1, date '2024-01-12', 'completed', 0.1, timestamp '2024-01-15 10:00:00');
insert into orders (id, customer_id, order_date, status, order_discount, updated_at) values
    (201, 2, date '2024-01-11', 'new', 0, timestamp '2024-01-15 10:00:00');
insert into orders (id, customer_id, order_date, status, order_discount, updated_at) values
    (301, 3, date '2024-01-13', 'completed', 0, timestamp '2024-01-15 10:00:00');

insert into order_items (order_id, product_id, quantity, price, updated_at) values
    (101, 1, 1, 10, timestamp '2024-01-15 10:00:00');
insert into order_items (order_id, product_id, quantity, price, updated_at) values
    (101, 2, 2, 20, timestamp '2024-01-15 10:00:00');
insert into order_items (order_id, product_id, quantity, price, updated_at) values
    (102, 1, 1, 50, timestamp '2024-01-15 10:00:00');
insert into order_items (order_id, product_id, quantity, price, updated_at) values
    (201, 1, 1, 100, timestamp '2024-01-15 10:00:00');
insert into order_items (order_id, product_id, quantity, price, updated_at) values
    (301, 1, 3, 7, timestamp '2024-01-15 10:00:00');

commit;
