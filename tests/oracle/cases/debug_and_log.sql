declare
    l_n number;
begin
    pkg_dwv_test.reset;

    select count(*) into l_n from dwv_log;
    pkg_dwv_test.eq('log empty', to_char(l_n), '0');

    pkg_dwv.set_log_table(true);
    pkg_dwv_test.add_row('inc_test_a', '1', 10, pkg_dwv_test.c_t1);
    pkg_dwv_test.capture_source('inc_test_a');
    pkg_dwv_test.merge_all;
    pkg_dwv.finalize;

    select count(*) into l_n from dwv_log where proc_name = 'pkg_dwv.capture_delta';
    pkg_dwv_test.eq('log capture', case when l_n > 0 then 'y' else 'n' end, 'y');
    select count(*) into l_n from dwv_log where proc_name = 'pkg_dwv.finalize';
    pkg_dwv_test.eq('log finalize', case when l_n > 0 then 'y' else 'n' end, 'y');
    select count(*)
    into l_n
    from dwv_watermark
    where target_table = pkg_dwv_test.c_target
      and target_owner = lower(sys_context('USERENV', 'CURRENT_SCHEMA'))
      and source_owner = lower(sys_context('USERENV', 'CURRENT_SCHEMA'));
    pkg_dwv_test.eq('wm owner', case when l_n > 0 then 'y' else 'n' end, 'y');
    select count(*) into l_n from dwv_log where message like 'lock released name=%';
    pkg_dwv_test.eq('log lock released', case when l_n > 0 then 'y' else 'n' end, 'y');

    pkg_dwv.initialize(pkg_dwv_test.c_target, 'all', 0, true);
    select count(*) into l_n from dwv_log where message like 'lock acquired name=%';
    pkg_dwv_test.eq('log lock acquired', case when l_n > 0 then 'y' else 'n' end, 'y');
    pkg_dwv_test.capture_source('inc_test_a');
    pkg_dwv_test.eq('debug keys', pkg_dwv_test.key_count, '0');
    pkg_dwv.finalize;

    pkg_dwv.set_log_table(false);
    pkg_dwv_test.pass('debug_and_log');
end;
/
