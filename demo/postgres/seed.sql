-- Three customers, four orders. Enough to read run.sql and see keys move.
truncate table order_items;
truncate table orders;
truncate table customers;
truncate table customer_metrics;

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
