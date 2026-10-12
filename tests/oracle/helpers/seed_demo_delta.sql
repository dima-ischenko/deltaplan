-- One delta slice on the small demo source. Updates the first customer and
-- inserts one new customer with the same shape. Safe to run again.
-- Leaves the watermark where the last run.sql put it.

declare
    l_as_of        date := sysdate;
    l_wm           date;
    l_customer_id  number;
    l_max_customer number;
    l_max_order    number;
begin
    select max(watermark)
    into l_wm
    from dpl_watermark
    where target_table = 'customer_metrics'
      and data_segment = 'all';

    if l_wm is not null and l_as_of <= l_wm then
        l_as_of := l_wm + 1 / 86400;
    end if;

    select min(id) into l_customer_id from customers;
    select max(id) into l_max_customer from customers;
    select max(id) into l_max_order from orders;

    update customers
    set name = name || '-u',
        updated_at = l_as_of
    where id = l_customer_id;

    update orders
    set status = case status
                     when 'completed' then 'cancelled'
                     when 'cancelled' then 'completed'
                     else 'completed'
                 end,
        order_discount = least(order_discount + 0.05, 0.5),
        updated_at = l_as_of
    where customer_id = l_customer_id;

    update order_items
    set price = round(price + 1, 2),
        updated_at = l_as_of
    where order_id in (
        select id from orders where customer_id = l_customer_id
    );

    insert into customers (id, name, region, updated_at)
    values (
        l_max_customer + 1,
        'customer-' || (l_max_customer + 1),
        'west',
        l_as_of
    );

    insert into orders (id, customer_id, order_date, status, order_discount, updated_at)
    values (
        l_max_order + 1,
        l_max_customer + 1,
        trunc(l_as_of),
        'completed',
        0,
        l_as_of
    );

    insert into order_items (order_id, product_id, quantity, price, updated_at)
    values (l_max_order + 1, 1, 2, 25.50, l_as_of);

    commit;
end;
/
