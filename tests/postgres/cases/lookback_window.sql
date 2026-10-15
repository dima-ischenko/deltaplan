create or replace procedure dwv_test.lookback_window()
language plpgsql as $$
declare
    c_noon constant timestamp := timestamp '2024-06-01 12:00:00';
begin
    call dwv_test.reset();
    insert into dwv_watermark (
        target_owner, target_table, data_slice,
        source_owner, source_table, watermark, updated_at
    )
    values (
        'public', 'inc_test_tgt', 'all',
        'public', 'inc_test_a', c_noon, clock_timestamp()::timestamp
    );
    call dwv_test.add_row('inc_test_a', 'a', 1, timestamp '2024-06-01 09:00:00');
    call dwv_test.add_row('inc_test_a', 'd', 1, timestamp '2024-06-01 10:00:00');
    call dwv_test.add_row('inc_test_a', 'b', 1, timestamp '2024-06-01 11:00:00');
    call dwv_test.add_row('inc_test_a', 'c', 1, timestamp '2024-06-01 13:00:00');
    perform initialize('inc_test_tgt', 'all', 2);
    call dwv_test.capture_source('inc_test_a');
    call dwv_test.eq('lookback keys', dwv_test.key_count(), '2');
    call dwv_test.merge_all();
    call dwv_test.eq('lookback tgt', dwv_test.tgt_state(), 'b:1:1,c:1:1');
    perform finalize();
    call dwv_test.eq('lookback wm', dwv_test.wm('inc_test_a'), '2024-06-01 13:00:00');
    call dwv_test.pass('lookback_window');
end;
$$;

call dwv_test.lookback_window();
