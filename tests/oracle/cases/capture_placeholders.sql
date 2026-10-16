declare
    l_id varchar2(10);
begin
    pkg_dwa_test.reset;

    insert into dwa_watermark (
        target_table, data_slice, source_table, watermark, updated_at
    ) values (
        pkg_dwa_test.c_target, 'all', 'inc_test_a', pkg_dwa_test.c_t1, sysdate
    );

    pkg_dwa_test.add_row('inc_test_a', 'a', 1, timestamp '2024-01-15 09:00:00');
    pkg_dwa_test.add_row('inc_test_a', 'b', 1, timestamp '2024-01-15 11:00:00');
    pkg_dwa_test.add_row('inc_test_a', 'c', 1, timestamp '2024-01-14 12:00:00');

    pkg_dwa.initialize(pkg_dwa_test.c_target, 'all', 0);
    pkg_dwa.capture_delta(
        'inc_test_a',
        q'[
            select id as pk_1, updated_at as watermark
            from inc_test_a
            where trunc(updated_at) >= trunc(:since)
              and updated_at > :since
        ]'
    );
    pkg_dwa_test.eq('since reuse keys', pkg_dwa_test.key_count, '1');
    select pk_1 into l_id from dwa_keys_tmp;
    pkg_dwa_test.eq('since reuse id', l_id, 'b');

    begin
        pkg_dwa.capture_delta(
            'inc_test_a',
            q'[select id as pk_1, updated_at as watermark from inc_test_a]'
        );
        pkg_dwa_test.expect_error('since missing', -20015);
    exception
        when others then
            if sqlcode != -20015 then
                raise;
            end if;
    end;

    pkg_dwa.finalize;

    pkg_dwa_test.reset;
    pkg_dwa_test.add_row('inc_test_a', 'a', 1, pkg_dwa_test.c_t1);
    pkg_dwa_test.add_row('inc_test_a', 'b', 1, pkg_dwa_test.c_t1);
    pkg_dwa.initialize(pkg_dwa_test.c_target, 'a', 0);
    pkg_dwa.capture_delta(
        'inc_test_a',
        q'[
            select id as pk_1, updated_at as watermark
            from inc_test_a
            where id = :data_slice
              and updated_at > :since
        ]'
    );
    pkg_dwa_test.eq('slice bind keys', pkg_dwa_test.key_count, '1');
    select pk_1 into l_id from dwa_keys_tmp;
    pkg_dwa_test.eq('slice bind id', l_id, 'a');
    pkg_dwa.finalize;

    pkg_dwa_test.pass('capture_placeholders');
end;
/
