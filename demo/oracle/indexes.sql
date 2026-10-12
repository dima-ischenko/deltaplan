create index ix_customers_updated on customers (updated_at);
create index ix_orders_customer on orders (customer_id);
create index ix_orders_updated on orders (updated_at);
create index ix_order_items_updated on order_items (updated_at);
