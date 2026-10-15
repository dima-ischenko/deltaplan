begin
    pkg_dwv_test.reset;
    pkg_dwv_test.add_row('inc_test_a', '1', 10, pkg_dwv_test.c_t1);
    pkg_dwv_test.add_row('inc_test_a', '2', 20, pkg_dwv_test.c_t1);
    pkg_dwv_test.add_row('inc_test_b', '2', 5, pkg_dwv_test.c_t1b);
    pkg_dwv_test.add_row('inc_test_b', '3', 7, pkg_dwv_test.c_t1b);
    pkg_dwv_test.capture_both;

    pkg_dwv_test.eq('static keys', pkg_dwv_test.key_count, '3');
    pkg_dwv_test.eq('static batch no', to_char(pkg_dwv.get_batch_no), to_char(null));
    pkg_dwv_test.merge_all;
    pkg_dwv_test.eq('static tgt', pkg_dwv_test.tgt_state, '1:10:1,2:25:1,3:7:1');

    pkg_dwv.finalize;
    pkg_dwv_test.eq('static wm a', pkg_dwv_test.wm('inc_test_a'), '2024-01-15 10:00:00');
    pkg_dwv_test.eq('static wm b', pkg_dwv_test.wm('inc_test_b'), '2024-01-15 10:00:01');
    pkg_dwv_test.eq('static other tracking', pkg_dwv_test.tracking_count('other_tgt'), '0');
    pkg_dwv_test.eq('static closed', pkg_dwv.get_target_table, to_char(null));

    pkg_dwv.initialize(pkg_dwv_test.c_target, 'all', 0);
    pkg_dwv_test.capture_both;
    pkg_dwv_test.eq('static second keys', pkg_dwv_test.key_count, '0');
    pkg_dwv_test.merge_all;
    pkg_dwv.finalize;
    pkg_dwv_test.eq('static second wm a', pkg_dwv_test.wm('inc_test_a'), '2024-01-15 10:00:00');
    pkg_dwv_test.eq('static second tgt', pkg_dwv_test.tgt_state, '1:10:1,2:25:1,3:7:1');

    update inc_test_a
    set amount = 50,
        updated_at = pkg_dwv_test.c_t2
    where id = '2';

    pkg_dwv.initialize(pkg_dwv_test.c_target, 'all', 0);
    pkg_dwv_test.capture_both;
    pkg_dwv_test.eq('static delta keys', pkg_dwv_test.key_count, '1');
    pkg_dwv_test.merge_all;
    pkg_dwv.finalize;
    pkg_dwv_test.eq('static delta tgt', pkg_dwv_test.tgt_state, '1:10:1,2:55:2,3:7:1');
    pkg_dwv_test.eq('static delta wm a', pkg_dwv_test.wm('inc_test_a'), '2024-02-01 00:00:00');
    pkg_dwv_test.eq('static delta wm b', pkg_dwv_test.wm('inc_test_b'), '2024-01-15 10:00:01');

    pkg_dwv_test.pass('static_without_batches');
end;
/
