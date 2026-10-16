-- What the last run.sql did. After seed.sql you should see 3 metrics and 3 watermarks.
set pagesize 50
set linesize 200

prompt --- sources
select (select count(*) from customers) as customers,
       (select count(*) from orders) as orders,
       (select count(*) from order_items) as order_items,
       (select count(*) from customer_metrics) as customer_metrics
from dual;

prompt --- customer_metrics (first 20 rows)
select * from (
    select * from customer_metrics order by customer_id
) where rownum <= 20;

prompt --- dwa_watermark
select source_table, watermark, updated_at
from dwa_watermark
where target_table = 'customer_metrics'
  and data_slice = 'all'
order by source_table;
