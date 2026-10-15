declare
    l_wm_a varchar2(19);
    l_wm_b varchar2(19);
    l_diff number;
begin
    pkg_dwv_test.reset;
    pkg_dwv_test.add_row('inc_test_a', 'a', 10, pkg_dwv_test.c_t1);
    pkg_dwv_test.add_row('inc_test_a', 'b', 20, pkg_dwv_test.c_t1);
    pkg_dwv_test.add_row('inc_test_b', 'b', 3, pkg_dwv_test.c_t1b);
    pkg_dwv_test.add_row('inc_test_b', 'c', 4, pkg_dwv_test.c_t1b);
    pkg_dwv_test.capture_both;
    pkg_dwv_test.merge_all;
    pkg_dwv.finalize;

    l_wm_a := pkg_dwv_test.wm('inc_test_a');
    l_wm_b := pkg_dwv_test.wm('inc_test_b');
    delete from inc_test_expect;
    insert into inc_test_expect (id, amount, touch)
    select id, amount, touch
    from inc_test_tgt;

    delete from inc_test_tgt;
    delete from dwv_watermark
    where target_table = pkg_dwv_test.c_target;
    commit;

    pkg_dwv.initialize(pkg_dwv_test.c_target, 'all', 0);
    pkg_dwv_test.capture_both;
    pkg_dwv.prepare_batches(p_batch_size => 1);

    while pkg_dwv.next_batch loop
        pkg_dwv_test.merge_batch;
        pkg_dwv.finish_batch;
    end loop;

    pkg_dwv.finalize;

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

    pkg_dwv_test.eq('same rows', to_char(l_diff), '0');
    pkg_dwv_test.eq('same wm a', pkg_dwv_test.wm('inc_test_a'), l_wm_a);
    pkg_dwv_test.eq('same wm b', pkg_dwv_test.wm('inc_test_b'), l_wm_b);
    pkg_dwv_test.pass('same_result');
end;
/
