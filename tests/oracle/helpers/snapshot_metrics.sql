-- Keep the incremental result, then clear the target so the next run.sql
-- is a full refresh from the default watermark.

begin
    execute immediate 'drop table customer_metrics_inc purge';
exception
    when others then
        if sqlcode != -942 then
            raise;
        end if;
end;
/

create table customer_metrics_inc as
select customer_id, min_amount, max_amount, avg_amount, last_order_id, cnt_completed
from customer_metrics;

truncate table customer_metrics;

delete from dpl_watermark
where target_table = 'customer_metrics';

commit;
