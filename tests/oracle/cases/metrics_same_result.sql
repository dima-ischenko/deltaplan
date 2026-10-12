-- Incremental passes vs full refresh, with batches and without.

declare
    l_full number;
    l_inc  number;
    l_src  number;
    l_diff number;
begin
    seed_customer_metrics;
    run_incremental_passes(1);
    snapshot_customer_metrics(p_reset => true);
    run_customer_metrics(1);

    l_diff := customer_metrics_xor;
    select count(*) into l_full from customer_metrics;
    select count(*) into l_inc from customer_metrics_inc;
    select count(*) into l_src from customers;

    if l_diff != 0 then
        raise_application_error(-20000, 'metrics batches xor=' || l_diff || ', expected 0');
    end if;
    if l_full != l_src or l_full != l_inc then
        raise_application_error(
            -20000,
            'metrics batches counts full=' || l_full || ' inc=' || l_inc || ' src=' || l_src
        );
    end if;

    dbms_output.put_line('metrics incremental=full refresh (batches): passed');

    seed_customer_metrics;
    run_incremental_passes(null);
    snapshot_customer_metrics(p_reset => true);
    run_customer_metrics(null);

    l_diff := customer_metrics_xor;
    select count(*) into l_full from customer_metrics;
    select count(*) into l_inc from customer_metrics_inc;
    select count(*) into l_src from customers;

    if l_diff != 0 then
        raise_application_error(-20000, 'metrics no-batch xor=' || l_diff || ', expected 0');
    end if;
    if l_full != l_src or l_full != l_inc then
        raise_application_error(
            -20000,
            'metrics no-batch counts full=' || l_full || ' inc=' || l_inc || ' src=' || l_src
        );
    end if;

    dbms_output.put_line('metrics incremental=full refresh (no batches): passed');
end;
/
