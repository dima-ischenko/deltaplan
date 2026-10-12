declare
begin
    pkg_dpl_test.reset;
    pkg_dpl_test.add_row('inc_test_a', 'a', 1, pkg_dpl_test.c_t1);
    pkg_dpl_test.add_row('inc_test_a', 'b', 2, pkg_dpl_test.c_t1);
    pkg_dpl_test.add_row('inc_test_a', 'c', 3, pkg_dpl_test.c_t1);
    pkg_dpl_test.capture_source('inc_test_a');
    pkg_dpl.prepare_batches(p_batch_size => 2);

    if not pkg_dpl.next_batch then
        pkg_dpl_test.fail('rerun', 'missing first batch');
    end if;

    pkg_dpl_test.merge_batch;
    pkg_dpl.finish_batch;
    pkg_dpl_test.eq('rerun after first', pkg_dpl_test.tgt_state, 'a:1:1,b:2:1');

    if not pkg_dpl.next_batch then
        pkg_dpl_test.fail('rerun', 'missing second batch');
    end if;

    pkg_dpl_test.merge_batch;
    rollback;

    pkg_dpl_test.eq('rerun rolled back', pkg_dpl_test.tgt_state, 'a:1:1,b:2:1');
    pkg_dpl_test.eq('rerun wm still old', pkg_dpl_test.wm('inc_test_a'), to_char(null));

    begin
        if pkg_dpl.next_batch then
            null;
        end if;
        pkg_dpl_test.expect_error('rerun lost batch', -20019);
    exception
        when others then
            if sqlcode != -20019 then
                raise;
            end if;
    end;

    pkg_dpl.initialize(pkg_dpl_test.c_target, 'all', 0);
    pkg_dpl_test.capture_source('inc_test_a');
    pkg_dpl.prepare_batches(p_batch_size => 2);

    while pkg_dpl.next_batch loop
        pkg_dpl_test.merge_batch;
        pkg_dpl.finish_batch;
    end loop;

    pkg_dpl_test.eq('rerun wm before finalize', pkg_dpl_test.wm('inc_test_a'), to_char(null));
    pkg_dpl.finalize;
    pkg_dpl_test.eq('rerun tgt', pkg_dpl_test.tgt_state, 'a:1:2,b:2:2,c:3:1');
    pkg_dpl_test.eq('rerun wm', pkg_dpl_test.wm('inc_test_a'), '2024-01-15 10:00:00');
    pkg_dpl_test.pass('rerun_after_failed_batch');
end;
/
