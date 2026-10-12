create or replace procedure dpl_test.resume_same_batch()
language plpgsql as $$
declare
    c_t1  constant timestamp := timestamp '2024-01-15 10:00:00';
    l_no  numeric;
    l_ids text;
begin
    call dpl_test.reset();
    call dpl_test.add_row('inc_test_a', 'a', 1, c_t1);
    call dpl_test.add_row('inc_test_a', 'b', 2, c_t1);
    call dpl_test.add_row('inc_test_a', 'c', 3, c_t1);
    call dpl_test.capture_source('inc_test_a');
    perform prepare_batches(2);
    commit;
    if not next_batch() then
        call dpl_test.fail('resume', 'missing first batch');
    end if;
    call dpl_test.merge_batch();
    perform finish_batch();
    commit;
    call dpl_test.eq('resume after first', dpl_test.tgt_state(), 'a:1:1,b:2:1');
    if not next_batch() then
        call dpl_test.fail('resume', 'missing second batch');
    end if;
    l_no := get_batch_no();
    l_ids := dpl_test.ids_in_batch();
    call dpl_test.merge_batch();
    rollback;
    call dpl_test.eq('resume rolled back', dpl_test.tgt_state(), 'a:1:1,b:2:1');
    if not next_batch() then
        call dpl_test.fail('resume', 'batch was not reopened');
    end if;
    call dpl_test.eq('resume batch no', get_batch_no()::integer::text, l_no::integer::text);
    call dpl_test.eq('resume keys', dpl_test.ids_in_batch(), l_ids);
    call dpl_test.merge_batch();
    perform finish_batch();
    if next_batch() then
        call dpl_test.fail('resume', 'unexpected extra batch');
    end if;
    call dpl_test.eq('resume wm still old', dpl_test.wm('inc_test_a'), null);
    perform finalize();
    call dpl_test.eq('resume tgt', dpl_test.tgt_state(), 'a:1:1,b:2:1,c:3:1');
    call dpl_test.eq('resume wm', dpl_test.wm('inc_test_a'), '2024-01-15 10:00:00');
    call dpl_test.pass('resume_same_batch');
end;
$$;

call dpl_test.resume_same_batch();
