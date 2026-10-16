begin
    pkg_dwa_test.reset;
    pkg_dwa_test.add_row('inc_test_a', 'a', 1, pkg_dwa_test.c_t1);
    pkg_dwa_test.add_row('inc_test_a', 'b', 2, pkg_dwa_test.c_t1);
    pkg_dwa_test.capture_source('inc_test_a');
    pkg_dwa.prepare_batches(p_batch_size => 1, p_commit_batch => false);

    while pkg_dwa.next_batch loop
        pkg_dwa_test.merge_batch;
        pkg_dwa.finish_batch;
    end loop;

    rollback;
    pkg_dwa_test.eq('rollback tgt', pkg_dwa_test.tgt_state, to_char(null));
    pkg_dwa.finalize;
    pkg_dwa_test.eq('rollback wm', pkg_dwa_test.wm('inc_test_a'), to_char(null));
    pkg_dwa_test.pass('rollback_without_commit');
end;
/
