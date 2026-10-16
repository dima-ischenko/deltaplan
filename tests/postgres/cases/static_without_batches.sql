create or replace procedure dwa_test.static_without_batches()
language plpgsql as $$
declare
    c_t1 constant timestamp := timestamp '2024-01-15 10:00:00';
    c_t2 constant timestamp := timestamp '2024-02-01 00:00:00';
begin
    call dwa_test.reset();
    call dwa_test.add_row('inc_test_a', '1', 10, c_t1);
    call dwa_test.add_row('inc_test_a', '2', 20, c_t1);
    call dwa_test.add_row('inc_test_b', '2', 5, c_t1 + interval '1 second');
    call dwa_test.add_row('inc_test_b', '3', 7, c_t1 + interval '1 second');
    call dwa_test.capture_both();

    call dwa_test.eq('static keys', dwa_test.key_count(), '3');
    call dwa_test.merge_all();
    call dwa_test.eq('static tgt', dwa_test.tgt_state(), '1:10:1,2:25:1,3:7:1');
    perform finalize();
    call dwa_test.eq('static wm a', dwa_test.wm('inc_test_a'), '2024-01-15 10:00:00');
    call dwa_test.eq('static wm b', dwa_test.wm('inc_test_b'), '2024-01-15 10:00:01');
    call dwa_test.eq('static other tracking', dwa_test.tracking_count('other_tgt'), '0');
    call dwa_test.expect_dwa(
        'static closed',
        'DWA-20001',
        $sql$select capture_delta(
            'inc_test_a',
            'select id as pk_1, updated_at as watermark from inc_test_a where updated_at > :since'
        )$sql$
    );

    perform initialize('inc_test_tgt', 'all', 0);
    call dwa_test.capture_both();
    call dwa_test.eq('static second keys', dwa_test.key_count(), '0');
    call dwa_test.merge_all();
    perform finalize();
    call dwa_test.eq('static second wm a', dwa_test.wm('inc_test_a'), '2024-01-15 10:00:00');
    call dwa_test.eq('static second tgt', dwa_test.tgt_state(), '1:10:1,2:25:1,3:7:1');

    update inc_test_a
    set amount = 50,
        updated_at = c_t2
    where id = '2';

    perform initialize('inc_test_tgt', 'all', 0);
    call dwa_test.capture_both();
    call dwa_test.eq('static delta keys', dwa_test.key_count(), '1');
    call dwa_test.merge_all();
    perform finalize();
    call dwa_test.eq('static delta tgt', dwa_test.tgt_state(), '1:10:1,2:55:2,3:7:1');
    call dwa_test.eq('static delta wm a', dwa_test.wm('inc_test_a'), '2024-02-01 00:00:00');
    call dwa_test.eq('static delta wm b', dwa_test.wm('inc_test_b'), '2024-01-15 10:00:01');
    call dwa_test.pass('static_without_batches');
end;
$$;

call dwa_test.static_without_batches();
