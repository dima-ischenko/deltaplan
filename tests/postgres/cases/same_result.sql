create or replace procedure dpl_test.same_result()
language plpgsql as $$
declare
    c_t1   constant timestamp := timestamp '2024-01-15 10:00:00';
    l_wm_a text;
    l_wm_b text;
    l_diff integer;
begin
    call dpl_test.reset();
    call dpl_test.add_row('inc_test_a', 'a', 10, c_t1);
    call dpl_test.add_row('inc_test_a', 'b', 20, c_t1);
    call dpl_test.add_row('inc_test_b', 'b', 3, c_t1 + interval '1 second');
    call dpl_test.add_row('inc_test_b', 'c', 4, c_t1 + interval '1 second');
    call dpl_test.capture_both();
    call dpl_test.merge_all();
    perform finalize();
    l_wm_a := dpl_test.wm('inc_test_a');
    l_wm_b := dpl_test.wm('inc_test_b');
    delete from inc_test_expect;
    insert into inc_test_expect (id, amount, touch)
    select id, amount, touch from inc_test_tgt;
    delete from inc_test_tgt;
    delete from dpl_watermark where target_table = 'inc_test_tgt';
    commit;

    perform initialize('inc_test_tgt', 'all', 0);
    call dpl_test.capture_both();
    perform prepare_batches(1);
    while next_batch() loop
        call dpl_test.merge_batch();
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
    call dpl_test.eq('same rows', l_diff::text, '0');
    call dpl_test.eq('same wm a', dpl_test.wm('inc_test_a'), l_wm_a);
    call dpl_test.eq('same wm b', dpl_test.wm('inc_test_b'), l_wm_b);
    call dpl_test.pass('same_result');
end;
$$;

call dpl_test.same_result();
