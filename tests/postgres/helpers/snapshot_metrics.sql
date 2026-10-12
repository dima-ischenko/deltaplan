-- Keep the incremental result, then clear the target so the next run.sql
-- is a full refresh from the default watermark.

drop table if exists customer_metrics_inc;

create table customer_metrics_inc as
select customer_id, min_amount, max_amount, avg_amount, last_order_id, cnt_completed
from customer_metrics;

truncate table customer_metrics;

delete from dpl_watermark
where target_table = 'customer_metrics';
