-- Incremental passes vs full refresh, with batches and without.

do $check$
declare
    l_full integer;
    l_inc  integer;
    l_src  integer;
    l_diff integer;
begin
    call dwv_test.seed_customer_metrics();
    call dwv_test.run_incremental_passes(1);
    call dwv_test.snapshot_customer_metrics(true);
    call dwv_test.run_customer_metrics(1);

    l_diff := dwv_test.customer_metrics_xor();
    select count(*) into l_full from customer_metrics;
    select count(*) into l_inc from customer_metrics_inc;
    select count(*) into l_src from customers;

    if l_diff is distinct from 0 then
        raise exception 'metrics batches xor=%, expected 0', l_diff;
    end if;
    if l_full is distinct from l_src or l_full is distinct from l_inc then
        raise exception 'metrics batches counts full=% inc=% src=%', l_full, l_inc, l_src;
    end if;

    raise notice 'metrics incremental=full refresh (batches): passed';

    call dwv_test.seed_customer_metrics();
    call dwv_test.run_incremental_passes(null);
    call dwv_test.snapshot_customer_metrics(true);
    call dwv_test.run_customer_metrics(null);

    l_diff := dwv_test.customer_metrics_xor();
    select count(*) into l_full from customer_metrics;
    select count(*) into l_inc from customer_metrics_inc;
    select count(*) into l_src from customers;

    if l_diff is distinct from 0 then
        raise exception 'metrics no-batch xor=%, expected 0', l_diff;
    end if;
    if l_full is distinct from l_src or l_full is distinct from l_inc then
        raise exception 'metrics no-batch counts full=% inc=% src=%', l_full, l_inc, l_src;
    end if;

    raise notice 'metrics incremental=full refresh (no batches): passed';
end;
$check$;
