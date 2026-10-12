create or replace procedure dpl_test.rollback_without_commit()
language plpgsql as $$
declare
    c_t1 constant timestamp := timestamp '2024-01-15 10:00:00';
begin
    call dpl_test.reset();
    call dpl_test.add_row('inc_test_a', 'a', 1, c_t1);
    call dpl_test.add_row('inc_test_a', 'b', 2, c_t1);
    call dpl_test.capture_source('inc_test_a');
    perform prepare_batches(1);
    while next_batch() loop
        call dpl_test.merge_batch();
        perform finish_batch();
    end loop;
    rollback;
    call dpl_test.eq('rollback tgt', dpl_test.tgt_state(), null);
    perform finalize();
    call dpl_test.eq('rollback wm', dpl_test.wm('inc_test_a'), null);
    call dpl_test.pass('rollback_without_commit');
end;
$$;

call dpl_test.rollback_without_commit();
