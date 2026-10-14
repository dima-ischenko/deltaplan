declare
    l_n number;
begin
    pkg_dpl_test.reset;

    select count(*) into l_n from dpl_log;
    pkg_dpl_test.eq('log empty', to_char(l_n), '0');

    pkg_dpl.set_log_table(true);
    pkg_dpl_test.add_row('inc_test_a', '1', 10, pkg_dpl_test.c_t1);
    pkg_dpl_test.capture_source('inc_test_a');
    pkg_dpl_test.merge_all;
    pkg_dpl.finalize;

    select count(*) into l_n from dpl_log where proc_name = 'pkg_dpl.capture_delta';
    pkg_dpl_test.eq('log capture', case when l_n > 0 then 'y' else 'n' end, 'y');
    select count(*) into l_n from dpl_log where proc_name = 'pkg_dpl.finalize';
    pkg_dpl_test.eq('log finalize', case when l_n > 0 then 'y' else 'n' end, 'y');

    pkg_dpl.initialize(pkg_dpl_test.c_target, 'all', 0, true);
    pkg_dpl_test.capture_source('inc_test_a');
    pkg_dpl_test.eq('debug keys', pkg_dpl_test.key_count, '0');
    pkg_dpl.finalize;

    pkg_dpl.set_log_table(false);
    pkg_dpl_test.pass('debug_and_log');
end;
/
