create or replace procedure dwa_test.rollback_without_commit()
language plpgsql as $$
declare
    c_t1 constant timestamp := timestamp '2024-01-15 10:00:00';
begin
    call dwa_test.reset();
    call dwa_test.add_row('inc_test_a', 'a', 1, c_t1);
    call dwa_test.add_row('inc_test_a', 'b', 2, c_t1);
    call dwa_test.capture_source('inc_test_a');
    perform prepare_batches(p_batch_size => 1);
    while next_batch() loop
        call dwa_test.merge_batch();
        perform finish_batch();
    end loop;
    rollback;
    call dwa_test.eq('rollback tgt', dwa_test.tgt_state(), null);
    perform finalize();
    call dwa_test.eq('rollback wm', dwa_test.wm('inc_test_a'), null);
    call dwa_test.pass('rollback_without_commit');
end;
$$;

call dwa_test.rollback_without_commit();
