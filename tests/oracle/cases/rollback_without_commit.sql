begin
    pkg_dpl_test.reset;
    pkg_dpl_test.add_row('inc_test_a', 'a', 1, pkg_dpl_test.c_t1);
    pkg_dpl_test.add_row('inc_test_a', 'b', 2, pkg_dpl_test.c_t1);
    pkg_dpl_test.capture_source('inc_test_a');
    pkg_dpl.prepare_batches(p_batch_size => 1, p_commit => false);

    while pkg_dpl.next_batch loop
        pkg_dpl_test.merge_batch;
        pkg_dpl.finish_batch;
    end loop;

    rollback;
    pkg_dpl_test.eq('rollback tgt', pkg_dpl_test.tgt_state, to_char(null));
    pkg_dpl.finalize;
    pkg_dpl_test.eq('rollback wm', pkg_dpl_test.wm('inc_test_a'), to_char(null));
    pkg_dpl_test.pass('rollback_without_commit');
end;
/
