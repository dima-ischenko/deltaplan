create or replace procedure dwa_test.debug_and_log()
language plpgsql as $$
declare
    c_t1 constant timestamp := timestamp '2024-01-15 10:00:00';
    l_n  integer;
begin
    call dwa_test.reset();

    select count(*)::integer into l_n from dwa_log;
    call dwa_test.eq('log empty', l_n::text, '0');

    perform initialize('inc_test_tgt', 'all', 0, false, true);
    call dwa_test.add_row('inc_test_a', '1', 10, c_t1);
    call dwa_test.capture_source('inc_test_a');
    call dwa_test.merge_all();
    perform finalize();

    select count(*)::integer into l_n from dwa_log where proc_name = 'capture_delta';
    call dwa_test.eq('log capture', case when l_n > 0 then 'y' else 'n' end, 'y');
    select count(*)::integer into l_n from dwa_log where proc_name = 'finalize';
    call dwa_test.eq('log finalize', case when l_n > 0 then 'y' else 'n' end, 'y');
    select count(*)::integer
    into l_n
    from dwa_watermark
    where target_table = 'inc_test_tgt'
      and target_owner = 'public'
      and source_owner = 'public';
    call dwa_test.eq('wm owner', case when l_n > 0 then 'y' else 'n' end, 'y');
    select count(*)::integer into l_n from dwa_log where message like 'lock released name=%';
    call dwa_test.eq('log lock released', case when l_n > 0 then 'y' else 'n' end, 'y');

    perform initialize('inc_test_tgt', 'all', 0, true, true);
    select count(*)::integer into l_n from dwa_log where message like 'lock acquired name=%';
    call dwa_test.eq('log lock acquired', case when l_n > 0 then 'y' else 'n' end, 'y');
    call dwa_test.capture_source('inc_test_a');
    call dwa_test.eq('debug keys', dwa_test.key_count(), '0');
    perform finalize();

    call dwa_test.pass('debug_and_log');
end;
$$;

call dwa_test.debug_and_log();
