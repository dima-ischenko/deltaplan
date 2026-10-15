declare
    l_rows number;
    l_temp number;
begin
    pkg_dwv_test.reset;
    pkg_dwv_test.add_row('inc_test_a', 'a', 10, pkg_dwv_test.c_t1);
    pkg_dwv_test.add_row('inc_test_a', 'b', 20, pkg_dwv_test.c_t1);
    pkg_dwv_test.add_row('inc_test_b', 'a', 1, pkg_dwv_test.c_t1b);
    pkg_dwv_test.add_row('inc_test_b', 'b', 2, pkg_dwv_test.c_t1b);
    pkg_dwv_test.capture_both;
    pkg_dwv.prepare_batches(p_batch_size => 10);

    if not pkg_dwv.next_batch then
        pkg_dwv_test.fail('one pk', 'missing batch');
    end if;

    select count(*) into l_rows from dwv_batch_tmp;
    select count(*)
    into l_temp
    from dwv_keys_tmp;

    pkg_dwv_test.eq('one pk keys', pkg_dwv_test.ids_in_batch, 'a,b');
    pkg_dwv_test.eq('one pk batch rows', to_char(l_rows), '2');
    pkg_dwv_test.eq('one pk temp rows', to_char(l_temp), '4');
    pkg_dwv_test.merge_batch;
    pkg_dwv.finish_batch;

    if pkg_dwv.next_batch then
        pkg_dwv_test.fail('one pk', 'second batch');
    end if;

    pkg_dwv.finalize;
    pkg_dwv_test.eq('one pk tgt', pkg_dwv_test.tgt_state, 'a:11:1,b:22:1');
    pkg_dwv_test.pass('one_pk_one_batch');
end;
/
