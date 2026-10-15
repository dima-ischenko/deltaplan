begin
    pkg_dwv_test.reset;

    insert into dwv_watermark (
        target_table, data_slice, source_table, watermark, updated_at
    ) values (
        pkg_dwv_test.c_target, 'all', 'inc_test_a', pkg_dwv_test.c_noon, sysdate
    );

    pkg_dwv_test.add_row('inc_test_a', 'a', 1, timestamp '2024-06-01 09:00:00');
    pkg_dwv_test.add_row('inc_test_a', 'd', 1, timestamp '2024-06-01 10:00:00');
    pkg_dwv_test.add_row('inc_test_a', 'b', 1, timestamp '2024-06-01 11:00:00');
    pkg_dwv_test.add_row('inc_test_a', 'c', 1, timestamp '2024-06-01 13:00:00');

    pkg_dwv.initialize(pkg_dwv_test.c_target, 'all', 2);
    pkg_dwv_test.capture_source('inc_test_a');
    pkg_dwv_test.eq('lookback keys', pkg_dwv_test.key_count, '2');
    pkg_dwv_test.merge_all;
    pkg_dwv_test.eq('lookback tgt', pkg_dwv_test.tgt_state, 'b:1:1,c:1:1');
    pkg_dwv.finalize;
    pkg_dwv_test.eq('lookback wm', pkg_dwv_test.wm('inc_test_a'), '2024-06-01 13:00:00');
    pkg_dwv_test.pass('lookback_window');
end;
/
