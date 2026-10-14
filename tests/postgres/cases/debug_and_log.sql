create or replace procedure dpl_test.debug_and_log()
language plpgsql as $$
declare
    c_t1 constant timestamp := timestamp '2024-01-15 10:00:00';
    l_n  integer;
begin
    call dpl_test.reset();

    select count(*)::integer into l_n from dpl_log;
    call dpl_test.eq('log empty', l_n::text, '0');

    perform set_log_table(true);
    call dpl_test.add_row('inc_test_a', '1', 10, c_t1);
    call dpl_test.capture_source('inc_test_a');
    call dpl_test.merge_all();
    perform finalize();

    select count(*)::integer into l_n from dpl_log where proc_name = 'capture_delta';
    call dpl_test.eq('log capture', case when l_n > 0 then 'y' else 'n' end, 'y');
    select count(*)::integer into l_n from dpl_log where proc_name = 'finalize';
    call dpl_test.eq('log finalize', case when l_n > 0 then 'y' else 'n' end, 'y');
    select count(*)::integer into l_n from dpl_log where message like 'lock released name=%';
    call dpl_test.eq('log lock released', case when l_n > 0 then 'y' else 'n' end, 'y');

    perform initialize('inc_test_tgt', 'all', 0, true);
    select count(*)::integer into l_n from dpl_log where message like 'lock acquired name=%';
    call dpl_test.eq('log lock acquired', case when l_n > 0 then 'y' else 'n' end, 'y');
    call dpl_test.capture_source('inc_test_a');
    call dpl_test.eq('debug keys', dpl_test.key_count(), '0');
    perform finalize();

    perform set_log_table(false);
    call dpl_test.pass('debug_and_log');
end;
$$;

call dpl_test.debug_and_log();
