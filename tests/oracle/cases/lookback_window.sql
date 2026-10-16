begin
    pkg_dwa_test.reset;

    insert into dwa_watermark (
        target_table, data_slice, source_table, watermark, updated_at
    ) values (
        pkg_dwa_test.c_target, 'all', 'inc_test_a', pkg_dwa_test.c_noon, sysdate
    );

    pkg_dwa_test.add_row('inc_test_a', 'a', 1, timestamp '2024-06-01 09:00:00');
    pkg_dwa_test.add_row('inc_test_a', 'd', 1, timestamp '2024-06-01 10:00:00');
    pkg_dwa_test.add_row('inc_test_a', 'b', 1, timestamp '2024-06-01 11:00:00');
    pkg_dwa_test.add_row('inc_test_a', 'c', 1, timestamp '2024-06-01 13:00:00');

    pkg_dwa.initialize(p_target_table => pkg_dwa_test.c_target, p_data_slice => 'all', p_lookback_hours => 2);
    pkg_dwa_test.capture_source('inc_test_a');
    pkg_dwa_test.eq('lookback keys', pkg_dwa_test.key_count, '2');
    pkg_dwa_test.merge_all;
    pkg_dwa_test.eq('lookback tgt', pkg_dwa_test.tgt_state, 'b:1:1,c:1:1');
    pkg_dwa.finalize;
    pkg_dwa_test.eq('lookback wm', pkg_dwa_test.wm('inc_test_a'), '2024-06-01 13:00:00');
    pkg_dwa_test.pass('lookback_window');
end;
/
