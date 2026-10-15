begin
    pkg_dwv_test.reset;
    pkg_dwv_test.add_row('inc_test_a', 'a', 1, pkg_dwv_test.c_t1);
    pkg_dwv_test.add_row('inc_test_a', 'b', 2, pkg_dwv_test.c_t1);
    pkg_dwv_test.capture_source('inc_test_a');
    pkg_dwv.prepare_batches(p_batch_size => 1, p_commit_batch => false);

    while pkg_dwv.next_batch loop
        pkg_dwv_test.merge_batch;
        pkg_dwv.finish_batch;
    end loop;

    rollback;
    pkg_dwv_test.eq('rollback tgt', pkg_dwv_test.tgt_state, to_char(null));
    pkg_dwv.finalize;
    pkg_dwv_test.eq('rollback wm', pkg_dwv_test.wm('inc_test_a'), to_char(null));
    pkg_dwv_test.pass('rollback_without_commit');
end;
/
