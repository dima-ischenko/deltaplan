-- Fixture for metrics_* cases. Not the demo playground.
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
    last_order_id  integer,
    cnt_completed  numeric,
    mt_change_date timestamp
);
