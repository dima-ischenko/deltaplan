do $check$
declare
    l_diff integer;
    l_inc  integer;
    l_full integer;
    l_src  integer;
begin
    select count(*) into l_inc from customer_metrics_inc;
    select count(*) into l_full from customer_metrics;
    select count(*) into l_src from customers;

    select count(*)::integer
    into l_diff
    from (
        (select customer_id, min_amount, max_amount, avg_amount, last_order_id, cnt_completed
         from customer_metrics
         except
         select customer_id, min_amount, max_amount, avg_amount, last_order_id, cnt_completed
         from customer_metrics_inc)
        union all
        (select customer_id, min_amount, max_amount, avg_amount, last_order_id, cnt_completed
         from customer_metrics_inc
         except
         select customer_id, min_amount, max_amount, avg_amount, last_order_id, cnt_completed
         from customer_metrics)
    ) d;

    if l_inc is distinct from 5 then
        raise exception 'demo inc metrics=%, expected 5', l_inc;
    end if;
    if l_full is distinct from l_src or l_full is distinct from l_inc then
        raise exception 'demo full metrics=% inc=% src=%', l_full, l_inc, l_src;
    end if;
    if l_diff is distinct from 0 then
        raise exception 'demo xor diff=%, expected 0', l_diff;
    end if;

    raise notice 'demo incremental=full refresh: passed';
end;
$check$;
