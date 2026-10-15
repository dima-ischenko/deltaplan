declare
    l_step number := 0;
    l_no   number;
begin
    pkg_dwv_test.reset;
    pkg_dwv_test.add_row('inc_test_a', 'a', 1, pkg_dwv_test.c_t1);
    pkg_dwv_test.add_row('inc_test_a', 'b', 2, pkg_dwv_test.c_t1);
    pkg_dwv_test.add_row('inc_test_a', 'c', 3, pkg_dwv_test.c_t1);
    pkg_dwv_test.add_row('inc_test_a', 'd', 4, pkg_dwv_test.c_t1);
    pkg_dwv_test.add_row('inc_test_a', 'e', 5, pkg_dwv_test.c_t1);
    pkg_dwv_test.capture_source('inc_test_a');

    pkg_dwv.prepare_batches(p_batch_size => 2);

    while pkg_dwv.next_batch loop
        l_step := l_step + 1;
        l_no := pkg_dwv.get_batch_no;

        insert into inc_test_seen (batch_no, id)
        select l_no, pk_1
        from dwv_batch_tmp;

        pkg_dwv_test.merge_batch;

        if l_step = 1 then
            pkg_dwv_test.eq('open batch', to_char(l_no), '1');
            pkg_dwv_test.eq('open keys', pkg_dwv_test.ids_in_batch, 'a,b');
            pkg_dwv_test.eq('open tgt', pkg_dwv_test.tgt_state, 'a:1:1,b:2:1');
            pkg_dwv_test.eq('open wm', pkg_dwv_test.wm('inc_test_a'), to_char(null));
        end if;

        pkg_dwv.finish_batch;
    end loop;

    pkg_dwv_test.eq('batches', to_char(l_step), '3');
    pkg_dwv_test.eq('seen 1', pkg_dwv_test.seen(1), 'a,b');
    pkg_dwv_test.eq('seen 2', pkg_dwv_test.seen(2), 'c,d');
    pkg_dwv_test.eq('seen 3', pkg_dwv_test.seen(3), 'e');
    pkg_dwv_test.eq('batch tgt before finalize', pkg_dwv_test.tgt_state, 'a:1:1,b:2:1,c:3:1,d:4:1,e:5:1');
    pkg_dwv_test.eq('batch wm before finalize', pkg_dwv_test.wm('inc_test_a'), to_char(null));

    pkg_dwv.finalize;
    pkg_dwv_test.eq('batch wm', pkg_dwv_test.wm('inc_test_a'), '2024-01-15 10:00:00');
    pkg_dwv_test.pass('static_batches');
end;
/
