create or replace procedure dpl_test.rerun_after_failed_batch()
language plpgsql as $$
declare
    c_t1 constant timestamp := timestamp '2024-01-15 10:00:00';
begin
    call dpl_test.reset();
    call dpl_test.add_row('inc_test_a', 'a', 1, c_t1);
    call dpl_test.add_row('inc_test_a', 'b', 2, c_t1);
    call dpl_test.add_row('inc_test_a', 'c', 3, c_t1);
    call dpl_test.capture_source('inc_test_a');
    perform prepare_batches(2);
    if not next_batch() then
        call dpl_test.fail('rerun', 'missing first batch');
    end if;
    call dpl_test.merge_batch();
    perform finish_batch();
    commit;
    call dpl_test.eq('rerun after first', dpl_test.tgt_state(), 'a:1:1,b:2:1');
    if not next_batch() then
        call dpl_test.fail('rerun', 'missing second batch');
    end if;
    call dpl_test.merge_batch();
    rollback;
    call dpl_test.eq('rerun rolled back', dpl_test.tgt_state(), 'a:1:1,b:2:1');
    call dpl_test.eq('rerun wm still old', dpl_test.wm('inc_test_a'), null);

    perform initialize('inc_test_tgt', 'all', 0);
    call dpl_test.capture_source('inc_test_a');
    perform prepare_batches(2);
    while next_batch() loop
        call dpl_test.merge_batch();
        perform finish_batch();
    end loop;
    call dpl_test.eq('rerun wm before finalize', dpl_test.wm('inc_test_a'), null);
    perform finalize();
    call dpl_test.eq('rerun tgt', dpl_test.tgt_state(), 'a:1:2,b:2:2,c:3:1');
    call dpl_test.eq('rerun wm', dpl_test.wm('inc_test_a'), '2024-01-15 10:00:00');
    call dpl_test.pass('rerun_after_failed_batch');
end;
$$;

call dpl_test.rerun_after_failed_batch();
