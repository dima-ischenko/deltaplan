declare
    l_diff number;
    l_inc  number;
    l_full number;
    l_src  number;
begin
    select count(*) into l_inc from customer_metrics_inc;
    select count(*) into l_full from customer_metrics;
    select count(*) into l_src from customers;

    select count(*)
    into l_diff
    from (
        (select customer_id, min_amount, max_amount, avg_amount, last_order_id, cnt_completed
         from customer_metrics
         minus
         select customer_id, min_amount, max_amount, avg_amount, last_order_id, cnt_completed
         from customer_metrics_inc)
        union all
        (select customer_id, min_amount, max_amount, avg_amount, last_order_id, cnt_completed
         from customer_metrics_inc
         minus
         select customer_id, min_amount, max_amount, avg_amount, last_order_id, cnt_completed
         from customer_metrics)
    );

    if l_inc != 5 then
        raise_application_error(-20000, 'demo inc metrics=' || l_inc || ', expected 5');
    end if;
    if l_full != l_src or l_full != l_inc then
        raise_application_error(
            -20000,
            'demo full metrics=' || l_full || ' inc=' || l_inc || ' src=' || l_src
        );
    end if;
    if l_diff != 0 then
        raise_application_error(-20000, 'demo xor diff=' || l_diff || ', expected 0');
    end if;

    dbms_output.put_line('demo incremental=full refresh: passed');
end;
/
