create or replace procedure dwv_test.rollback_without_commit()
language plpgsql as $$
declare
    c_t1 constant timestamp := timestamp '2024-01-15 10:00:00';
begin
    call dwv_test.reset();
    call dwv_test.add_row('inc_test_a', 'a', 1, c_t1);
    call dwv_test.add_row('inc_test_a', 'b', 2, c_t1);
    call dwv_test.capture_source('inc_test_a');
    perform prepare_batches(1);
    while next_batch() loop
        call dwv_test.merge_batch();
        perform finish_batch();
    end loop;
    rollback;
    call dwv_test.eq('rollback tgt', dwv_test.tgt_state(), null);
    perform finalize();
    call dwv_test.eq('rollback wm', dwv_test.wm('inc_test_a'), null);
    call dwv_test.pass('rollback_without_commit');
end;
$$;

call dwv_test.rollback_without_commit();
