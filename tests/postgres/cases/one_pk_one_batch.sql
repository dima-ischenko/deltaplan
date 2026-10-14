create or replace procedure dpl_test.one_pk_one_batch()
language plpgsql as $$
declare
    c_t1   constant timestamp := timestamp '2024-01-15 10:00:00';
    l_rows integer;
    l_temp integer;
begin
    call dpl_test.reset();
    call dpl_test.add_row('inc_test_a', 'a', 10, c_t1);
    call dpl_test.add_row('inc_test_a', 'b', 20, c_t1);
    call dpl_test.add_row('inc_test_b', 'a', 1, c_t1 + interval '1 second');
    call dpl_test.add_row('inc_test_b', 'b', 2, c_t1 + interval '1 second');
    call dpl_test.capture_both();
    perform prepare_batches(10);
    if not next_batch() then
        call dpl_test.fail('one pk', 'missing batch');
    end if;
    select count(*)::integer into l_rows from dpl_batch_tmp;
    select count(*)::integer into l_temp
    from dpl_keys_tmp;
    call dpl_test.eq('one pk keys', dpl_test.ids_in_batch(), 'a,b');
    call dpl_test.eq('one pk batch rows', l_rows::text, '2');
    call dpl_test.eq('one pk temp rows', l_temp::text, '4');
    call dpl_test.merge_batch();
    perform finish_batch();
    if next_batch() then
        call dpl_test.fail('one pk', 'second batch');
    end if;
    perform finalize();
    call dpl_test.eq('one pk tgt', dpl_test.tgt_state(), 'a:11:1,b:22:1');
    call dpl_test.pass('one_pk_one_batch');
end;
$$;

call dpl_test.one_pk_one_batch();
