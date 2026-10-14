begin
    pkg_dpl_test.reset;

    pkg_dpl.initialize(pkg_dpl_test.c_target, 'all', 0);
    pkg_dpl.initialize(pkg_dpl_test.c_target, 'all', 0);

    pkg_dpl.initialize(pkg_dpl_test.c_target, 'fr', 0);
    pkg_dpl.finalize;
    pkg_dpl.initialize(pkg_dpl_test.c_target, 'all', 0);
    pkg_dpl.finalize;

    pkg_dpl_test.pass('run_lock');
end;
/
