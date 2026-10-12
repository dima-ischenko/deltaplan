-- DML that does not move updated_at, and a hard delete, must not change
-- the incremental result. A full refresh from the current source does.

declare
    l_silent_id  constant number := 2;
    l_deleted_id constant number := 3;
    l_old_max    number;
    l_new_max    number;
    l_inc        number;
    l_full       number;
    l_src        number;
    l_still      number;
begin
    seed_customer_metrics;
    run_incremental_passes(1);
    snapshot_customer_metrics(p_reset => false);

    select max_amount
    into l_old_max
    from customer_metrics
    where customer_id = l_silent_id;

    update order_items
    set price = price + 100
    where order_id in (
        select id from orders where customer_id = l_silent_id
    );

    delete from order_items
    where order_id in (
        select id from orders where customer_id = l_deleted_id
    );
    delete from orders where customer_id = l_deleted_id;
    delete from customers where id = l_deleted_id;
    commit;

    run_customer_metrics(1);

    if customer_metrics_xor != 0 then
        raise_application_error(
            -20000,
            'metrics silent dml incremental xor=' || customer_metrics_xor || ', expected 0'
        );
    end if;

    select count(*) into l_still
    from customer_metrics
    where customer_id = l_deleted_id;
    if l_still != 1 then
        raise_application_error(-20000, 'metrics silent dml dropped deleted key');
    end if;

    snapshot_customer_metrics(p_reset => true);
    run_customer_metrics(1);

    if customer_metrics_xor = 0 then
        raise_application_error(-20000, 'metrics silent dml full refresh xor=0, expected a difference');
    end if;

    select count(*) into l_inc from customer_metrics_inc;
    select count(*) into l_full from customer_metrics;
    select count(*) into l_src from customers;
    select max_amount
    into l_new_max
    from customer_metrics
    where customer_id = l_silent_id;

    if l_full != l_src then
        raise_application_error(-20000, 'metrics silent dml full=' || l_full || ' src=' || l_src);
    end if;
    if l_full >= l_inc then
        raise_application_error(-20000, 'metrics silent dml full did not drop the deleted key');
    end if;
    if l_new_max = l_old_max then
        raise_application_error(-20000, 'metrics silent dml full did not see the silent price change');
    end if;

    dbms_output.put_line('metrics silent dml: passed');
end;
/
