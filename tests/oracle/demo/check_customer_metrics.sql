-- After example_customer_metrics.sql: three keys, three watermarks.
declare
    l_metrics number;
    l_wm      number;
begin
    select count(*) into l_metrics from customer_metrics;
    select count(*)
    into l_wm
    from dpl_watermark
    where target_table = 'customer_metrics'
      and data_segment = 'all';

    if l_metrics != 3 then
        raise_application_error(-20000, 'example metrics=' || l_metrics || ', expected 3');
    end if;
    if l_wm != 3 then
        raise_application_error(-20000, 'example watermarks=' || l_wm || ', expected 3');
    end if;

    dbms_output.put_line('example_customer_metrics: passed');
end;
/
