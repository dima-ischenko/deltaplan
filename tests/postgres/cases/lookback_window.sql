create or replace procedure dwa_test.lookback_window()
language plpgsql as $$
declare
    c_noon constant timestamp := timestamp '2024-06-01 12:00:00';
begin
    call dwa_test.reset();
    insert into dwa_watermark (
        target_owner, target_table, data_slice,
        source_owner, source_table, watermark, updated_at
    )
    values (
        'public', 'inc_test_tgt', 'all',
        'public', 'inc_test_a', c_noon, clock_timestamp()::timestamp
    );
    call dwa_test.add_row('inc_test_a', 'a', 1, timestamp '2024-06-01 09:00:00');
    call dwa_test.add_row('inc_test_a', 'd', 1, timestamp '2024-06-01 10:00:00');
    call dwa_test.add_row('inc_test_a', 'b', 1, timestamp '2024-06-01 11:00:00');
    call dwa_test.add_row('inc_test_a', 'c', 1, timestamp '2024-06-01 13:00:00');
    perform initialize('inc_test_tgt', 'all', 2);
    call dwa_test.capture_source('inc_test_a');
    call dwa_test.eq('lookback keys', dwa_test.key_count(), '2');
    call dwa_test.merge_all();
    call dwa_test.eq('lookback tgt', dwa_test.tgt_state(), 'b:1:1,c:1:1');
    perform finalize();
    call dwa_test.eq('lookback wm', dwa_test.wm('inc_test_a'), '2024-06-01 13:00:00');
    call dwa_test.pass('lookback_window');
end;
$$;

call dwa_test.lookback_window();
