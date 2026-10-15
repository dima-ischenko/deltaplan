create or replace procedure dwv_test.static_without_batches()
language plpgsql as $$
declare
    c_t1 constant timestamp := timestamp '2024-01-15 10:00:00';
    c_t2 constant timestamp := timestamp '2024-02-01 00:00:00';
begin
    call dwv_test.reset();
    call dwv_test.add_row('inc_test_a', '1', 10, c_t1);
    call dwv_test.add_row('inc_test_a', '2', 20, c_t1);
    call dwv_test.add_row('inc_test_b', '2', 5, c_t1 + interval '1 second');
    call dwv_test.add_row('inc_test_b', '3', 7, c_t1 + interval '1 second');
    call dwv_test.capture_both();

    call dwv_test.eq('static keys', dwv_test.key_count(), '3');
    call dwv_test.eq('static batch no', get_batch_no()::text, null);
    call dwv_test.merge_all();
    call dwv_test.eq('static tgt', dwv_test.tgt_state(), '1:10:1,2:25:1,3:7:1');
    perform finalize();
    call dwv_test.eq('static wm a', dwv_test.wm('inc_test_a'), '2024-01-15 10:00:00');
    call dwv_test.eq('static wm b', dwv_test.wm('inc_test_b'), '2024-01-15 10:00:01');
    call dwv_test.eq('static other tracking', dwv_test.tracking_count('other_tgt'), '0');
    call dwv_test.eq('static closed', get_target_table(), null);

    perform initialize('inc_test_tgt', 'all', 0);
    call dwv_test.capture_both();
    call dwv_test.eq('static second keys', dwv_test.key_count(), '0');
    call dwv_test.merge_all();
    perform finalize();
    call dwv_test.eq('static second wm a', dwv_test.wm('inc_test_a'), '2024-01-15 10:00:00');
    call dwv_test.eq('static second tgt', dwv_test.tgt_state(), '1:10:1,2:25:1,3:7:1');

    update inc_test_a
    set amount = 50,
        updated_at = c_t2
    where id = '2';

    perform initialize('inc_test_tgt', 'all', 0);
    call dwv_test.capture_both();
    call dwv_test.eq('static delta keys', dwv_test.key_count(), '1');
    call dwv_test.merge_all();
    perform finalize();
    call dwv_test.eq('static delta tgt', dwv_test.tgt_state(), '1:10:1,2:55:2,3:7:1');
    call dwv_test.eq('static delta wm a', dwv_test.wm('inc_test_a'), '2024-02-01 00:00:00');
    call dwv_test.eq('static delta wm b', dwv_test.wm('inc_test_b'), '2024-01-15 10:00:01');
    call dwv_test.pass('static_without_batches');
end;
$$;

call dwv_test.static_without_batches();
