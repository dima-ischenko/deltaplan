declare
    l_rows number;
    l_temp number;
begin
    pkg_dpl_test.reset;
    pkg_dpl_test.add_row('inc_test_a', 'a', 10, pkg_dpl_test.c_t1);
    pkg_dpl_test.add_row('inc_test_a', 'b', 20, pkg_dpl_test.c_t1);
    pkg_dpl_test.add_row('inc_test_b', 'a', 1, pkg_dpl_test.c_t1b);
    pkg_dpl_test.add_row('inc_test_b', 'b', 2, pkg_dpl_test.c_t1b);
    pkg_dpl_test.capture_both;
    pkg_dpl.prepare_batches(p_batch_size => 10);

    if not pkg_dpl.next_batch then
        pkg_dpl_test.fail('one pk', 'missing batch');
    end if;

    select count(*) into l_rows from dpl_batch_tmp;
    select count(*)
    into l_temp
    from dpl_keys_tmp;

    pkg_dpl_test.eq('one pk keys', pkg_dpl_test.ids_in_batch, 'a,b');
    pkg_dpl_test.eq('one pk batch rows', to_char(l_rows), '2');
    pkg_dpl_test.eq('one pk temp rows', to_char(l_temp), '4');
    pkg_dpl_test.merge_batch;
    pkg_dpl.finish_batch;

    if pkg_dpl.next_batch then
        pkg_dpl_test.fail('one pk', 'second batch');
    end if;

    pkg_dpl.finalize;
    pkg_dpl_test.eq('one pk tgt', pkg_dpl_test.tgt_state, 'a:11:1,b:22:1');
    pkg_dpl_test.pass('one_pk_one_batch');
end;
/
