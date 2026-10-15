create or replace procedure dwv_test.one_pk_one_batch()
language plpgsql as $$
declare
    c_t1   constant timestamp := timestamp '2024-01-15 10:00:00';
    l_rows integer;
    l_temp integer;
begin
    call dwv_test.reset();
    call dwv_test.add_row('inc_test_a', 'a', 10, c_t1);
    call dwv_test.add_row('inc_test_a', 'b', 20, c_t1);
    call dwv_test.add_row('inc_test_b', 'a', 1, c_t1 + interval '1 second');
    call dwv_test.add_row('inc_test_b', 'b', 2, c_t1 + interval '1 second');
    call dwv_test.capture_both();
    perform prepare_batches(10);
    if not next_batch() then
        call dwv_test.fail('one pk', 'missing batch');
    end if;
    select count(*)::integer into l_rows from dwv_batch_tmp;
    select count(*)::integer into l_temp
    from dwv_keys_tmp;
    call dwv_test.eq('one pk keys', dwv_test.ids_in_batch(), 'a,b');
    call dwv_test.eq('one pk batch rows', l_rows::text, '2');
    call dwv_test.eq('one pk temp rows', l_temp::text, '4');
    call dwv_test.merge_batch();
    perform finish_batch();
    if next_batch() then
        call dwv_test.fail('one pk', 'second batch');
    end if;
    perform finalize();
    call dwv_test.eq('one pk tgt', dwv_test.tgt_state(), 'a:11:1,b:22:1');
    call dwv_test.pass('one_pk_one_batch');
end;
$$;

call dwv_test.one_pk_one_batch();
