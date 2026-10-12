declare
    l_no  number;
    l_ids varchar2(10);
begin
    pkg_dpl_test.reset;
    pkg_dpl_test.add_row('inc_test_a', 'a', 1, pkg_dpl_test.c_t1);
    pkg_dpl_test.add_row('inc_test_a', 'b', 2, pkg_dpl_test.c_t1);
    pkg_dpl_test.add_row('inc_test_a', 'c', 3, pkg_dpl_test.c_t1);
    pkg_dpl_test.capture_source('inc_test_a');
    pkg_dpl.prepare_batches(p_batch_size => 2);

    if not pkg_dpl.next_batch then
        pkg_dpl_test.fail('resume', 'missing first batch');
    end if;

    pkg_dpl_test.merge_batch;
    pkg_dpl.finish_batch;
    pkg_dpl_test.eq('resume after first', pkg_dpl_test.tgt_state, 'a:1:1,b:2:1');

    if not pkg_dpl.next_batch then
        pkg_dpl_test.fail('resume', 'missing second batch');
    end if;

    l_no := pkg_dpl.get_batch_no;
    l_ids := pkg_dpl_test.ids_in_batch;
    pkg_dpl_test.merge_batch;
    rollback;

    pkg_dpl_test.eq('resume rolled back', pkg_dpl_test.tgt_state, 'a:1:1,b:2:1');

    if not pkg_dpl.next_batch then
        pkg_dpl_test.fail('resume', 'batch was not reopened');
    end if;

    pkg_dpl_test.eq('resume batch no', to_char(pkg_dpl.get_batch_no), to_char(l_no));
    pkg_dpl_test.eq('resume keys', pkg_dpl_test.ids_in_batch, l_ids);
    pkg_dpl_test.merge_batch;
    pkg_dpl.finish_batch;

    if pkg_dpl.next_batch then
        pkg_dpl_test.fail('resume', 'unexpected extra batch');
    end if;

    pkg_dpl_test.eq('resume wm still old', pkg_dpl_test.wm('inc_test_a'), to_char(null));
    pkg_dpl.finalize;
    pkg_dpl_test.eq('resume tgt', pkg_dpl_test.tgt_state, 'a:1:1,b:2:1,c:3:1');
    pkg_dpl_test.eq('resume wm', pkg_dpl_test.wm('inc_test_a'), '2024-01-15 10:00:00');
    pkg_dpl_test.pass('resume_same_batch');
end;
/
