begin
    pkg_dwa_test.reset;
    pkg_dwa_test.add_row('inc_test_a', '1', 10, pkg_dwa_test.c_t1);
    pkg_dwa_test.add_row('inc_test_a', '2', 20, pkg_dwa_test.c_t1);
    pkg_dwa_test.add_row('inc_test_b', '2', 5, pkg_dwa_test.c_t1b);
    pkg_dwa_test.add_row('inc_test_b', '3', 7, pkg_dwa_test.c_t1b);
    pkg_dwa_test.capture_both;

    pkg_dwa_test.eq('static keys', pkg_dwa_test.key_count, '3');
    pkg_dwa_test.merge_all;
    pkg_dwa_test.eq('static tgt', pkg_dwa_test.tgt_state, '1:10:1,2:25:1,3:7:1');

    pkg_dwa.finalize;
    pkg_dwa_test.eq('static wm a', pkg_dwa_test.wm('inc_test_a'), '2024-01-15 10:00:00');
    pkg_dwa_test.eq('static wm b', pkg_dwa_test.wm('inc_test_b'), '2024-01-15 10:00:01');
    pkg_dwa_test.eq('static other tracking', pkg_dwa_test.tracking_count('other_tgt'), '0');
    begin
        pkg_dwa.capture_delta(
            'inc_test_a',
            'select id as pk_1, updated_at as watermark from inc_test_a where updated_at > :since'
        );
        pkg_dwa_test.expect_error('static closed', -20001);
    exception
        when others then
            if sqlcode != -20001 then
                raise;
            end if;
    end;

    pkg_dwa.initialize(pkg_dwa_test.c_target, 'all', 0);
    pkg_dwa_test.capture_both;
    pkg_dwa_test.eq('static second keys', pkg_dwa_test.key_count, '0');
    pkg_dwa_test.merge_all;
    pkg_dwa.finalize;
    pkg_dwa_test.eq('static second wm a', pkg_dwa_test.wm('inc_test_a'), '2024-01-15 10:00:00');
    pkg_dwa_test.eq('static second tgt', pkg_dwa_test.tgt_state, '1:10:1,2:25:1,3:7:1');

    update inc_test_a
    set amount = 50,
        updated_at = pkg_dwa_test.c_t2
    where id = '2';

    pkg_dwa.initialize(pkg_dwa_test.c_target, 'all', 0);
    pkg_dwa_test.capture_both;
    pkg_dwa_test.eq('static delta keys', pkg_dwa_test.key_count, '1');
    pkg_dwa_test.merge_all;
    pkg_dwa.finalize;
    pkg_dwa_test.eq('static delta tgt', pkg_dwa_test.tgt_state, '1:10:1,2:55:2,3:7:1');
    pkg_dwa_test.eq('static delta wm a', pkg_dwa_test.wm('inc_test_a'), '2024-02-01 00:00:00');
    pkg_dwa_test.eq('static delta wm b', pkg_dwa_test.wm('inc_test_b'), '2024-01-15 10:00:01');

    pkg_dwa_test.pass('static_without_batches');
end;
/
