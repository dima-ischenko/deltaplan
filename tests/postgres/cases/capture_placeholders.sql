create or replace procedure dwa_test.capture_placeholders()
language plpgsql as $$
declare
    l_id text;
    c_t1 constant timestamp := timestamp '2024-01-15 10:00:00';
begin
    call dwa_test.reset();
    insert into dwa_watermark (
        target_owner, target_table, data_slice,
        source_owner, source_table, watermark, updated_at
    )
    values (
        'public', 'inc_test_tgt', 'all',
        'public', 'inc_test_a', c_t1, clock_timestamp()::timestamp
    );
    call dwa_test.add_row('inc_test_a', 'a', 1, timestamp '2024-01-15 09:00:00');
    call dwa_test.add_row('inc_test_a', 'b', 1, timestamp '2024-01-15 11:00:00');
    call dwa_test.add_row('inc_test_a', 'c', 1, timestamp '2024-01-14 12:00:00');
    perform initialize('inc_test_tgt', 'all', 0);
    perform capture_delta(
        'inc_test_a',
        $sql$
            select id as pk_1, updated_at as watermark
            from inc_test_a
            where date_trunc('day', updated_at) >= date_trunc('day', :since)
              and updated_at > :since
        $sql$
    );
    call dwa_test.eq('since reuse keys', dwa_test.key_count(), '1');
    select pk_1 into l_id from dwa_keys_tmp;
    call dwa_test.eq('since reuse id', l_id, 'b');
    call dwa_test.expect_dwa(
        'since missing',
        'DWA-20015',
        $sql$select capture_delta(
            'inc_test_a',
            'select id as pk_1, updated_at as watermark from inc_test_a'
        )$sql$
    );
    perform finalize();

    call dwa_test.reset();
    call dwa_test.add_row('inc_test_a', 'a', 1, c_t1);
    call dwa_test.add_row('inc_test_a', 'b', 1, c_t1);
    perform initialize('inc_test_tgt', 'a', 0);
    perform capture_delta(
        'inc_test_a',
        $sql$
            select id as pk_1, updated_at as watermark
            from inc_test_a
            where id = :data_slice
              and updated_at > :since
        $sql$
    );
    call dwa_test.eq('slice bind keys', dwa_test.key_count(), '1');
    select pk_1 into l_id from dwa_keys_tmp;
    call dwa_test.eq('slice bind id', l_id, 'a');
    perform finalize();

    call dwa_test.pass('capture_placeholders');
end;
$$;

call dwa_test.capture_placeholders();
