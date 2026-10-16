declare
begin
    pkg_dwa_test.reset;
    pkg_dwa_test.add_row('inc_test_a', 'a', 1, pkg_dwa_test.c_t1);
    pkg_dwa_test.add_row('inc_test_a', 'b', 2, pkg_dwa_test.c_t1);
    pkg_dwa_test.add_row('inc_test_a', 'c', 3, pkg_dwa_test.c_t1);
    pkg_dwa_test.capture_source('inc_test_a');
    pkg_dwa.prepare_batches(p_batch_size => 2);

    if not pkg_dwa.next_batch then
        pkg_dwa_test.fail('rerun', 'missing first batch');
    end if;

    pkg_dwa_test.merge_batch;
    pkg_dwa.finish_batch;
    pkg_dwa_test.eq('rerun after first', pkg_dwa_test.tgt_state, 'a:1:1,b:2:1');

    if not pkg_dwa.next_batch then
        pkg_dwa_test.fail('rerun', 'missing second batch');
    end if;

    pkg_dwa_test.merge_batch;
    rollback;

    pkg_dwa_test.eq('rerun rolled back', pkg_dwa_test.tgt_state, 'a:1:1,b:2:1');
    pkg_dwa_test.eq('rerun wm still old', pkg_dwa_test.wm('inc_test_a'), to_char(null));

    begin
        if pkg_dwa.next_batch then
            null;
        end if;
        pkg_dwa_test.expect_error('rerun lost batch', -20019);
    exception
        when others then
            if sqlcode != -20019 then
                raise;
            end if;
    end;

    pkg_dwa.initialize(p_target_table => pkg_dwa_test.c_target, p_data_slice => 'all', p_lookback_hours => 0);
    pkg_dwa_test.capture_source('inc_test_a');
    pkg_dwa.prepare_batches(p_batch_size => 2);

    while pkg_dwa.next_batch loop
        pkg_dwa_test.merge_batch;
        pkg_dwa.finish_batch;
    end loop;

    pkg_dwa_test.eq('rerun wm before finalize', pkg_dwa_test.wm('inc_test_a'), to_char(null));
    pkg_dwa.finalize;
    pkg_dwa_test.eq('rerun tgt', pkg_dwa_test.tgt_state, 'a:1:2,b:2:2,c:3:1');
    pkg_dwa_test.eq('rerun wm', pkg_dwa_test.wm('inc_test_a'), '2024-01-15 10:00:00');
    pkg_dwa_test.pass('rerun_after_failed_batch');
end;
/
