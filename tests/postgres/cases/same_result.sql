create or replace procedure dwa_test.same_result()
language plpgsql as $$
declare
    c_t1   constant timestamp := timestamp '2024-01-15 10:00:00';
    l_wm_a text;
    l_wm_b text;
    l_diff integer;
begin
    call dwa_test.reset();
    call dwa_test.add_row('inc_test_a', 'a', 10, c_t1);
    call dwa_test.add_row('inc_test_a', 'b', 20, c_t1);
    call dwa_test.add_row('inc_test_b', 'b', 3, c_t1 + interval '1 second');
    call dwa_test.add_row('inc_test_b', 'c', 4, c_t1 + interval '1 second');
    call dwa_test.capture_both();
    call dwa_test.merge_all();
    perform finalize();
    l_wm_a := dwa_test.wm('inc_test_a');
    l_wm_b := dwa_test.wm('inc_test_b');
    delete from inc_test_expect;
    insert into inc_test_expect (id, amount, touch)
    select id, amount, touch from inc_test_tgt;
    delete from inc_test_tgt;
    delete from dwa_watermark where target_table = 'inc_test_tgt';
    commit;

    perform initialize(p_target_table => 'inc_test_tgt', p_data_slice => 'all', p_lookback_hours => 0);
    call dwa_test.capture_both();
    perform prepare_batches(p_batch_size => 1);
    while next_batch() loop
        call dwa_test.merge_batch();
        perform finish_batch();
    end loop;
    perform finalize();

    select count(*)::integer
    into l_diff
    from (
        (select id, amount, touch from inc_test_tgt
         except
         select id, amount, touch from inc_test_expect)
        union all
        (select id, amount, touch from inc_test_expect
         except
         select id, amount, touch from inc_test_tgt)
    ) d;
    call dwa_test.eq('same rows', l_diff::text, '0');
    call dwa_test.eq('same wm a', dwa_test.wm('inc_test_a'), l_wm_a);
    call dwa_test.eq('same wm b', dwa_test.wm('inc_test_b'), l_wm_b);
    call dwa_test.pass('same_result');
end;
$$;

call dwa_test.same_result();
