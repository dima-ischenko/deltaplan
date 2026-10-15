create or replace procedure dwv_test.static_batches()
language plpgsql as $$
declare
    c_t1   constant timestamp := timestamp '2024-01-15 10:00:00';
    l_step integer;
    l_no   numeric;
begin
    call dwv_test.reset();
    call dwv_test.add_row('inc_test_a', 'a', 1, c_t1);
    call dwv_test.add_row('inc_test_a', 'b', 2, c_t1);
    call dwv_test.add_row('inc_test_a', 'c', 3, c_t1);
    call dwv_test.add_row('inc_test_a', 'd', 4, c_t1);
    call dwv_test.add_row('inc_test_a', 'e', 5, c_t1);
    call dwv_test.capture_source('inc_test_a');
    perform prepare_batches(2);
    l_step := 0;
    while next_batch() loop
        l_step := l_step + 1;
        l_no := get_batch_no();
        insert into inc_test_seen (batch_no, id)
        select l_no, pk_1 from dwv_batch_tmp;
        call dwv_test.merge_batch();
        if l_step = 1 then
            call dwv_test.eq('open batch', l_no::integer::text, '1');
            call dwv_test.eq('open keys', dwv_test.ids_in_batch(), 'a,b');
            call dwv_test.eq('open tgt', dwv_test.tgt_state(), 'a:1:1,b:2:1');
            call dwv_test.eq('open wm', dwv_test.wm('inc_test_a'), null);
        end if;
        perform finish_batch();
    end loop;
    call dwv_test.eq('batches', l_step::text, '3');
    call dwv_test.eq('seen 1', dwv_test.seen(1), 'a,b');
    call dwv_test.eq('seen 2', dwv_test.seen(2), 'c,d');
    call dwv_test.eq('seen 3', dwv_test.seen(3), 'e');
    call dwv_test.eq('batch tgt before finalize', dwv_test.tgt_state(), 'a:1:1,b:2:1,c:3:1,d:4:1,e:5:1');
    call dwv_test.eq('batch wm before finalize', dwv_test.wm('inc_test_a'), null);
    perform finalize();
    call dwv_test.eq('batch wm', dwv_test.wm('inc_test_a'), '2024-01-15 10:00:00');
    call dwv_test.pass('static_batches');
end;
$$;

call dwv_test.static_batches();
