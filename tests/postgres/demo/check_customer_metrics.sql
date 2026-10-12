-- After example_customer_metrics.sql: three keys, three watermarks.
do $check$
declare
    l_metrics integer;
    l_wm      integer;
begin
    select count(*) into l_metrics from customer_metrics;
    select count(*)
    into l_wm
    from dpl_watermark
    where target_table = 'customer_metrics'
      and data_segment = 'all';

    if l_metrics is distinct from 3 then
        raise exception 'example metrics=%, expected 3', l_metrics;
    end if;
    if l_wm is distinct from 3 then
        raise exception 'example watermarks=%, expected 3', l_wm;
    end if;

    raise notice 'example_customer_metrics: passed';
end;
$check$;
