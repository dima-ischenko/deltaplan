-- DML that does not move updated_at, and a hard delete, must not change
-- the incremental result. A full refresh from the current source does.

do $check$
declare
    l_silent_id  constant integer := 2;
    l_deleted_id constant integer := 3;
    l_old_max    numeric;
    l_new_max    numeric;
    l_inc        integer;
    l_full       integer;
    l_src        integer;
    l_still      integer;
    l_diff       integer;
begin
    call dwa_test.seed_customer_metrics();
    call dwa_test.run_incremental_passes(1);
    call dwa_test.snapshot_customer_metrics(false);

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

    call dwa_test.run_customer_metrics(1);

    l_diff := dwa_test.customer_metrics_xor();
    if l_diff is distinct from 0 then
        raise exception 'metrics silent dml incremental xor=%, expected 0', l_diff;
    end if;

    select count(*) into l_still
    from customer_metrics
    where customer_id = l_deleted_id;
    if l_still is distinct from 1 then
        raise exception 'metrics silent dml dropped deleted key';
    end if;

    call dwa_test.snapshot_customer_metrics(true);
    call dwa_test.run_customer_metrics(1);

    l_diff := dwa_test.customer_metrics_xor();
    if l_diff = 0 then
        raise exception 'metrics silent dml full refresh xor=0, expected a difference';
    end if;

    select count(*) into l_inc from customer_metrics_inc;
    select count(*) into l_full from customer_metrics;
    select count(*) into l_src from customers;
    select max_amount
    into l_new_max
    from customer_metrics
    where customer_id = l_silent_id;

    if l_full is distinct from l_src then
        raise exception 'metrics silent dml full=% src=%', l_full, l_src;
    end if;
    if l_full >= l_inc then
        raise exception 'metrics silent dml full did not drop the deleted key';
    end if;
    if l_new_max is not distinct from l_old_max then
        raise exception 'metrics silent dml full did not see the silent price change';
    end if;

    raise notice 'metrics silent dml: passed';
end;
$check$;
