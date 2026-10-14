declare
    l_wm_a varchar2(19);
    l_wm_b varchar2(19);
    l_diff number;
begin
    pkg_dpl_test.reset;
    pkg_dpl_test.add_row('inc_test_a', 'a', 10, pkg_dpl_test.c_t1);
    pkg_dpl_test.add_row('inc_test_a', 'b', 20, pkg_dpl_test.c_t1);
    pkg_dpl_test.add_row('inc_test_b', 'b', 3, pkg_dpl_test.c_t1b);
    pkg_dpl_test.add_row('inc_test_b', 'c', 4, pkg_dpl_test.c_t1b);
    pkg_dpl_test.capture_both;
    pkg_dpl_test.merge_all;
    pkg_dpl.finalize;

    l_wm_a := pkg_dpl_test.wm('inc_test_a');
    l_wm_b := pkg_dpl_test.wm('inc_test_b');
    delete from inc_test_expect;
    insert into inc_test_expect (id, amount, touch)
    select id, amount, touch
    from inc_test_tgt;

    delete from inc_test_tgt;
    delete from dpl_watermark
    where target_table = pkg_dpl_test.c_target;
    commit;

    pkg_dpl.initialize(pkg_dpl_test.c_target, 'all', 0);
    pkg_dpl_test.capture_both;
    pkg_dpl.prepare_batches(p_batch_size => 1);

    while pkg_dpl.next_batch loop
        pkg_dpl_test.merge_batch;
        pkg_dpl.finish_batch;
    end loop;

    pkg_dpl.finalize;

    select count(*)
    into l_diff
    from (
        (select id, amount, touch from inc_test_tgt
         minus
         select id, amount, touch from inc_test_expect)
        union all
        (select id, amount, touch from inc_test_expect
         minus
         select id, amount, touch from inc_test_tgt)
    );

    pkg_dpl_test.eq('same rows', to_char(l_diff), '0');
    pkg_dpl_test.eq('same wm a', pkg_dpl_test.wm('inc_test_a'), l_wm_a);
    pkg_dpl_test.eq('same wm b', pkg_dpl_test.wm('inc_test_b'), l_wm_b);
    pkg_dpl_test.pass('same_result');
end;
/
