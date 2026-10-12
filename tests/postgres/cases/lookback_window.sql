create or replace procedure dpl_test.lookback_window()
language plpgsql as $$
declare
    c_noon constant timestamp := timestamp '2024-06-01 12:00:00';
begin
    call dpl_test.reset();
    insert into dpl_watermark (target_table, data_segment, source_table, watermark, updated_at)
    values ('inc_test_tgt', 'all', 'inc_test_a', c_noon, clock_timestamp()::timestamp);
    call dpl_test.add_row('inc_test_a', 'a', 1, timestamp '2024-06-01 09:00:00');
    call dpl_test.add_row('inc_test_a', 'd', 1, timestamp '2024-06-01 10:00:00');
    call dpl_test.add_row('inc_test_a', 'b', 1, timestamp '2024-06-01 11:00:00');
    call dpl_test.add_row('inc_test_a', 'c', 1, timestamp '2024-06-01 13:00:00');
    perform initialize('inc_test_tgt', 'all', 2);
    call dpl_test.capture_source('inc_test_a');
    call dpl_test.eq('lookback keys', dpl_test.key_count(), '2');
    call dpl_test.merge_all();
    call dpl_test.eq('lookback tgt', dpl_test.tgt_state(), 'b:1:1,c:1:1');
    perform finalize();
    call dpl_test.eq('lookback wm', dpl_test.wm('inc_test_a'), '2024-06-01 13:00:00');
    call dpl_test.pass('lookback_window');
end;
$$;

call dpl_test.lookback_window();
