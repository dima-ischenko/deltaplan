declare
    l_n number;
begin
    pkg_dwa_test.reset;

    select count(*) into l_n from dwa_log;
    pkg_dwa_test.eq('log empty', to_char(l_n), '0');

    pkg_dwa.initialize(p_target_table => pkg_dwa_test.c_target, p_data_slice => 'all', p_lookback_hours => 0, p_debug => false, p_log_table => true);
    pkg_dwa_test.add_row('inc_test_a', '1', 10, pkg_dwa_test.c_t1);
    pkg_dwa_test.capture_source('inc_test_a');
    pkg_dwa_test.merge_all;
    pkg_dwa.finalize;

    select count(*) into l_n from dwa_log where proc_name = 'pkg_dwa.capture_delta';
    pkg_dwa_test.eq('log capture', case when l_n > 0 then 'y' else 'n' end, 'y');
    select count(*) into l_n from dwa_log where proc_name = 'pkg_dwa.finalize';
    pkg_dwa_test.eq('log finalize', case when l_n > 0 then 'y' else 'n' end, 'y');
    select count(*)
    into l_n
    from dwa_watermark
    where target_table = pkg_dwa_test.c_target
      and target_owner = lower(sys_context('USERENV', 'CURRENT_SCHEMA'))
      and source_owner = lower(sys_context('USERENV', 'CURRENT_SCHEMA'));
    pkg_dwa_test.eq('wm owner', case when l_n > 0 then 'y' else 'n' end, 'y');
    select count(*) into l_n from dwa_log where message like 'lock released name=%';
    pkg_dwa_test.eq('log lock released', case when l_n > 0 then 'y' else 'n' end, 'y');

    pkg_dwa.initialize(p_target_table => pkg_dwa_test.c_target, p_data_slice => 'all', p_lookback_hours => 0, p_debug => true, p_log_table => true);
    select count(*) into l_n from dwa_log where message like 'lock acquired name=%';
    pkg_dwa_test.eq('log lock acquired', case when l_n > 0 then 'y' else 'n' end, 'y');
    pkg_dwa_test.capture_source('inc_test_a');
    pkg_dwa_test.eq('debug keys', pkg_dwa_test.key_count, '0');
    pkg_dwa.finalize;

    pkg_dwa_test.pass('debug_and_log');
end;
/
