create or replace procedure dwa_test.one_pk_one_batch()
language plpgsql as $$
declare
    c_t1   constant timestamp := timestamp '2024-01-15 10:00:00';
    l_rows integer;
    l_temp integer;
begin
    call dwa_test.reset();
    call dwa_test.add_row('inc_test_a', 'a', 10, c_t1);
    call dwa_test.add_row('inc_test_a', 'b', 20, c_t1);
    call dwa_test.add_row('inc_test_b', 'a', 1, c_t1 + interval '1 second');
    call dwa_test.add_row('inc_test_b', 'b', 2, c_t1 + interval '1 second');
    call dwa_test.capture_both();
    perform prepare_batches(10);
    if not next_batch() then
        call dwa_test.fail('one pk', 'missing batch');
    end if;
    select count(*)::integer into l_rows from dwa_batch_tmp;
    select count(*)::integer into l_temp
    from dwa_keys_tmp;
    call dwa_test.eq('one pk keys', dwa_test.ids_in_batch(), 'a,b');
    call dwa_test.eq('one pk batch rows', l_rows::text, '2');
    call dwa_test.eq('one pk temp rows', l_temp::text, '4');
    call dwa_test.merge_batch();
    perform finish_batch();
    if next_batch() then
        call dwa_test.fail('one pk', 'second batch');
    end if;
    perform finalize();
    call dwa_test.eq('one pk tgt', dwa_test.tgt_state(), 'a:11:1,b:22:1');
    call dwa_test.pass('one_pk_one_batch');
end;
$$;

call dwa_test.one_pk_one_batch();
