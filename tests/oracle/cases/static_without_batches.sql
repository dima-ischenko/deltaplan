begin
    pkg_dpl_test.reset;
    pkg_dpl_test.add_row('inc_test_a', '1', 10, pkg_dpl_test.c_t1);
    pkg_dpl_test.add_row('inc_test_a', '2', 20, pkg_dpl_test.c_t1);
    pkg_dpl_test.add_row('inc_test_b', '2', 5, pkg_dpl_test.c_t1);
    pkg_dpl_test.add_row('inc_test_b', '3', 7, pkg_dpl_test.c_t1);
    pkg_dpl_test.capture_both;

    insert into dpl_keys_tmp (
        target_table, data_segment, source_table,
        pk_1, pk_2, pk_3, watermark
    ) values (
        'other_tgt', 'all', 'inc_test_a',
        'z', null, null, pkg_dpl_test.c_t2
    );

    pkg_dpl_test.eq('static keys', pkg_dpl_test.key_count, '3');
    pkg_dpl_test.eq('static batch no', to_char(pkg_dpl.get_batch_no), to_char(null));
    pkg_dpl_test.merge_all;
    pkg_dpl_test.eq('static tgt', pkg_dpl_test.tgt_state, '1:10:1,2:25:1,3:7:1');

    pkg_dpl.finalize;
    pkg_dpl_test.eq('static wm a', pkg_dpl_test.wm('inc_test_a'), '2024-01-15 10:00:00');
    pkg_dpl_test.eq('static wm b', pkg_dpl_test.wm('inc_test_b'), '2024-01-15 10:00:00');
    pkg_dpl_test.eq('static other tracking', pkg_dpl_test.tracking_count('other_tgt'), '0');
    pkg_dpl_test.eq('static closed', pkg_dpl.get_target_table, to_char(null));

    pkg_dpl.initialize(pkg_dpl_test.c_target, 'all', 0);
    pkg_dpl_test.capture_both;
    pkg_dpl_test.eq('static second keys', pkg_dpl_test.key_count, '0');
    pkg_dpl_test.merge_all;
    pkg_dpl.finalize;
    pkg_dpl_test.eq('static second wm a', pkg_dpl_test.wm('inc_test_a'), '2024-01-15 10:00:00');
    pkg_dpl_test.eq('static second tgt', pkg_dpl_test.tgt_state, '1:10:1,2:25:1,3:7:1');

    update inc_test_a
    set amount = 50,
        updated_at = pkg_dpl_test.c_t2
    where id = '2';

    pkg_dpl.initialize(pkg_dpl_test.c_target, 'all', 0);
    pkg_dpl_test.capture_both;
    pkg_dpl_test.eq('static delta keys', pkg_dpl_test.key_count, '1');
    pkg_dpl_test.merge_all;
    pkg_dpl.finalize;
    pkg_dpl_test.eq('static delta tgt', pkg_dpl_test.tgt_state, '1:10:1,2:55:2,3:7:1');
    pkg_dpl_test.eq('static delta wm a', pkg_dpl_test.wm('inc_test_a'), '2024-02-01 00:00:00');
    pkg_dpl_test.eq('static delta wm b', pkg_dpl_test.wm('inc_test_b'), '2024-01-15 10:00:00');

    delete from dpl_keys_tmp where target_table = 'other_tgt';
    pkg_dpl_test.pass('static_without_batches');
end;
/
