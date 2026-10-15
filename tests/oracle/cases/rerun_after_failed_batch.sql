declare
begin
    pkg_dwv_test.reset;
    pkg_dwv_test.add_row('inc_test_a', 'a', 1, pkg_dwv_test.c_t1);
    pkg_dwv_test.add_row('inc_test_a', 'b', 2, pkg_dwv_test.c_t1);
    pkg_dwv_test.add_row('inc_test_a', 'c', 3, pkg_dwv_test.c_t1);
    pkg_dwv_test.capture_source('inc_test_a');
    pkg_dwv.prepare_batches(p_batch_size => 2);

    if not pkg_dwv.next_batch then
        pkg_dwv_test.fail('rerun', 'missing first batch');
    end if;

    pkg_dwv_test.merge_batch;
    pkg_dwv.finish_batch;
    pkg_dwv_test.eq('rerun after first', pkg_dwv_test.tgt_state, 'a:1:1,b:2:1');

    if not pkg_dwv.next_batch then
        pkg_dwv_test.fail('rerun', 'missing second batch');
    end if;

    pkg_dwv_test.merge_batch;
    rollback;

    pkg_dwv_test.eq('rerun rolled back', pkg_dwv_test.tgt_state, 'a:1:1,b:2:1');
    pkg_dwv_test.eq('rerun wm still old', pkg_dwv_test.wm('inc_test_a'), to_char(null));

    begin
        if pkg_dwv.next_batch then
            null;
        end if;
        pkg_dwv_test.expect_error('rerun lost batch', -20019);
    exception
        when others then
            if sqlcode != -20019 then
                raise;
            end if;
    end;

    pkg_dwv.initialize(pkg_dwv_test.c_target, 'all', 0);
    pkg_dwv_test.capture_source('inc_test_a');
    pkg_dwv.prepare_batches(p_batch_size => 2);

    while pkg_dwv.next_batch loop
        pkg_dwv_test.merge_batch;
        pkg_dwv.finish_batch;
    end loop;

    pkg_dwv_test.eq('rerun wm before finalize', pkg_dwv_test.wm('inc_test_a'), to_char(null));
    pkg_dwv.finalize;
    pkg_dwv_test.eq('rerun tgt', pkg_dwv_test.tgt_state, 'a:1:2,b:2:2,c:3:1');
    pkg_dwv_test.eq('rerun wm', pkg_dwv_test.wm('inc_test_a'), '2024-01-15 10:00:00');
    pkg_dwv_test.pass('rerun_after_failed_batch');
end;
/
