-- Tiny fixture for example_customer_metrics.sql. Three customers, four orders.
drop table if exists order_items;
drop table if exists orders;
drop table if exists customers;
drop table if exists customer_metrics;

create table customers (
    id         integer primary key,
    name       text not null,
    region     text not null,
    updated_at timestamp not null
);

create table orders (
    id             integer primary key,
    customer_id    integer not null,
    order_date     date not null,
    status         text not null,
    order_discount numeric not null,
    updated_at     timestamp not null,
    constraint ck_orders_status check (status in ('new', 'completed', 'cancelled'))
);

create table order_items (
    order_id   integer not null,
    product_id integer not null,
    quantity   numeric not null,
    price      numeric not null,
    updated_at timestamp not null,
    primary key (order_id, product_id)
);

create table customer_metrics (
    customer_id    integer primary key,
    min_amount     numeric,
    max_amount     numeric,
    avg_amount     numeric,
    cnt_completed  numeric,
    mt_change_date timestamp
);

insert into customers (id, name, region, updated_at) values
    (1, 'anna', 'north', timestamp '2024-01-15 10:00:00'),
    (2, 'ben', 'south', timestamp '2024-01-15 10:00:00'),
    (3, 'cara', 'east', timestamp '2024-01-15 10:00:00');

insert into orders (id, customer_id, order_date, status, order_discount, updated_at) values
    (101, 1, date '2024-01-10', 'completed', 0, timestamp '2024-01-15 10:00:00'),
    (102, 1, date '2024-01-12', 'completed', 0.1, timestamp '2024-01-15 10:00:00'),
    (201, 2, date '2024-01-11', 'new', 0, timestamp '2024-01-15 10:00:00'),
    (301, 3, date '2024-01-13', 'completed', 0, timestamp '2024-01-15 10:00:00');

insert into order_items (order_id, product_id, quantity, price, updated_at) values
    (101, 1, 1, 10, timestamp '2024-01-15 10:00:00'),
    (101, 2, 2, 20, timestamp '2024-01-15 10:00:00'),
    (102, 1, 1, 50, timestamp '2024-01-15 10:00:00'),
    (201, 1, 1, 100, timestamp '2024-01-15 10:00:00'),
    (301, 1, 3, 7, timestamp '2024-01-15 10:00:00');
