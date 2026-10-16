create or replace procedure dwa_test.rerun_after_failed_batch()
language plpgsql as $$
declare
    c_t1 constant timestamp := timestamp '2024-01-15 10:00:00';
begin
    call dwa_test.reset();
    call dwa_test.add_row('inc_test_a', 'a', 1, c_t1);
    call dwa_test.add_row('inc_test_a', 'b', 2, c_t1);
    call dwa_test.add_row('inc_test_a', 'c', 3, c_t1);
    call dwa_test.capture_source('inc_test_a');
    perform prepare_batches(2);
    if not next_batch() then
        call dwa_test.fail('rerun', 'missing first batch');
    end if;
    call dwa_test.merge_batch();
    perform finish_batch();
    commit;
    call dwa_test.eq('rerun after first', dwa_test.tgt_state(), 'a:1:1,b:2:1');
    if not next_batch() then
        call dwa_test.fail('rerun', 'missing second batch');
    end if;
    call dwa_test.merge_batch();
    rollback;
    call dwa_test.eq('rerun rolled back', dwa_test.tgt_state(), 'a:1:1,b:2:1');
    call dwa_test.eq('rerun wm still old', dwa_test.wm('inc_test_a'), null);

    perform initialize('inc_test_tgt', 'all', 0);
    call dwa_test.capture_source('inc_test_a');
    perform prepare_batches(2);
    while next_batch() loop
        call dwa_test.merge_batch();
        perform finish_batch();
    end loop;
    call dwa_test.eq('rerun wm before finalize', dwa_test.wm('inc_test_a'), null);
    perform finalize();
    call dwa_test.eq('rerun tgt', dwa_test.tgt_state(), 'a:1:2,b:2:2,c:3:1');
    call dwa_test.eq('rerun wm', dwa_test.wm('inc_test_a'), '2024-01-15 10:00:00');
    call dwa_test.pass('rerun_after_failed_batch');
end;
$$;

call dwa_test.rerun_after_failed_batch();
