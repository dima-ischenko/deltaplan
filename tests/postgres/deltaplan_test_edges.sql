-- Engine edges that the original suite did not cover.
-- Loaded after deltaplan_test.sql. Call deltaplan_test.run_edges().

create or replace procedure deltaplan_test.run_edges()
language plpgsql as $$
declare
    c_noon constant timestamp := timestamp '2024-06-01 12:00:00';
    l_cnt  integer;
    l_pk2  text;
    l_null boolean;
begin
    -- A row dated before 2000-01-01 is part of the first load.
    call deltaplan_test.reset();
    call deltaplan_test.add_row('inc_test_a', 'old', 4, timestamp '1999-12-31 23:00:00');
    call deltaplan.initialize('inc_test_tgt', 'all', 100000);
    call deltaplan_test.capture_source('inc_test_a');
    call deltaplan_test.eq('epoch keys', deltaplan_test.key_count(), '1');
    call deltaplan_test.merge_all();
    call deltaplan.finalize();
    call deltaplan_test.eq('epoch tgt', deltaplan_test.tgt_state(), 'old:4:1');
    call deltaplan_test.eq('epoch wm', deltaplan_test.wm('inc_test_a'), '1999-12-31 23:00:00');
    call deltaplan_test.pass('initial_bound_includes_history');

    -- Lookback may recapture an older value. The stored watermark stays put.
    call deltaplan_test.reset();
    insert into deltaplan_watermark (target_table, data_segment, source_table, watermark, updated_at)
    values ('inc_test_tgt', 'all', 'inc_test_a', c_noon, clock_timestamp()::timestamp);
    call deltaplan_test.add_row('inc_test_a', 'early', 1, timestamp '2024-06-01 11:00:00');
    call deltaplan.initialize('inc_test_tgt', 'all', 2);
    call deltaplan_test.capture_source('inc_test_a');
    call deltaplan_test.eq('kept keys', deltaplan_test.key_count(), '1');
    call deltaplan.finalize();
    call deltaplan_test.eq('kept wm', deltaplan_test.wm('inc_test_a'), '2024-06-01 12:00:00');
    call deltaplan_test.pass('watermark_does_not_move_backwards');

    -- A second segment has its own watermark. It still sees the source rows.
    call deltaplan_test.reset();
    call deltaplan_test.add_row('inc_test_a', 's', 1, c_noon);
    call deltaplan.initialize('inc_test_tgt', 'east', 0);
    call deltaplan_test.capture_source('inc_test_a');
    call deltaplan.finalize();
    select count(*)::integer into l_cnt
    from deltaplan_watermark
    where target_table = 'inc_test_tgt' and data_segment = 'east' and source_table = 'inc_test_a';
    call deltaplan_test.eq('segment east rows', l_cnt::text, '1');
    call deltaplan_test.eq('segment all untouched', deltaplan_test.wm('inc_test_a'), null);
    call deltaplan.initialize('inc_test_tgt', 'all', 0);
    call deltaplan_test.capture_source('inc_test_a');
    call deltaplan_test.eq('segment all keys', deltaplan_test.key_count(), '1');
    call deltaplan.finalize();
    call deltaplan_test.pass('segments_do_not_share_watermarks');

    -- value > :since, so a row stamped exactly at the watermark needs lookback.
    call deltaplan_test.reset();
    call deltaplan_test.add_row('inc_test_a', 'a', 1, c_noon);
    call deltaplan_test.capture_source('inc_test_a');
    call deltaplan.finalize();
    call deltaplan_test.add_row('inc_test_a', 'b', 2, c_noon);
    call deltaplan.initialize('inc_test_tgt', 'all', 0);
    call deltaplan_test.capture_source('inc_test_a');
    call deltaplan_test.eq('equal ts hidden', deltaplan_test.key_count(), '0');
    call deltaplan.initialize('inc_test_tgt', 'all', 0);
    call deltaplan.capture_delta(
        'inc_test_a',
        'select id as pk_1, null::text as pk_2, null::text as pk_3, '
        || 'updated_at as watermark from inc_test_a where updated_at > :since',
        1
    );
    call deltaplan_test.eq('equal ts lookback', deltaplan_test.key_count(), '2');
    call deltaplan_test.pass('equal_timestamp_needs_lookback');

    -- 1.5 hours before noon is 10:30. The bound itself is excluded.
    call deltaplan_test.reset();
    insert into deltaplan_watermark (target_table, data_segment, source_table, watermark, updated_at)
    values ('inc_test_tgt', 'all', 'inc_test_a', c_noon, clock_timestamp()::timestamp);
    call deltaplan_test.add_row('inc_test_a', 'a', 1, timestamp '2024-06-01 10:00:00');
    call deltaplan_test.add_row('inc_test_a', 'b', 1, timestamp '2024-06-01 10:30:00');
    call deltaplan_test.add_row('inc_test_a', 'c', 1, timestamp '2024-06-01 11:00:00');
    call deltaplan_test.add_row('inc_test_a', 'd', 1, timestamp '2024-06-01 12:30:00');
    call deltaplan.initialize('inc_test_tgt', 'all', 1.5);
    call deltaplan_test.capture_source('inc_test_a');
    call deltaplan_test.eq('fractional keys', deltaplan_test.key_count(), '2');
    call deltaplan_test.pass('fractional_lookback');

    -- Same business key twice, two watermarks. One key, and the later watermark wins.
    call deltaplan_test.reset();
    call deltaplan.capture_delta(
        'inc_test_a',
        $sql$
        select s.pk_1, s.pk_2, s.pk_3, s.watermark
        from (
            select 'p'::text as pk_1, null::text as pk_2, null::text as pk_3,
                   timestamp '2024-08-01 00:00:00' as watermark
            union all
            select 'p', null::text, null::text, timestamp '2024-08-02 00:00:00'
        ) s
        where s.watermark > :since
        $sql$
    );
    select count(*)::integer into l_cnt
    from deltaplan_keys
    where target_table = 'inc_test_tgt' and data_segment = 'all';
    call deltaplan_test.eq('dup raw rows', l_cnt::text, '2');
    call deltaplan_test.eq('dup distinct', deltaplan_test.key_count(), '1');
    select count(*)::integer into l_cnt from deltaplan_keyset;
    call deltaplan_test.eq('dup keyset', l_cnt::text, '1');
    call deltaplan.finalize();
    call deltaplan_test.eq('dup wm', deltaplan_test.wm('inc_test_a'), '2024-08-02 00:00:00');
    call deltaplan_test.pass('duplicate_keys_collapse');

    -- Null and empty pk parts are different keys. Null sorts first.
    call deltaplan_test.reset();
    call deltaplan.capture_delta(
        'inc_test_a',
        $sql$
        select s.pk_1, s.pk_2, s.pk_3, s.watermark
        from (
            select 'a'::text as pk_1, null::text as pk_2, null::text as pk_3,
                   timestamp '2024-09-01 00:00:00' as watermark
            union all
            select 'a', ''::text, null::text, timestamp '2024-09-01 00:00:00'
            union all
            select 'a', 'x'::text, null::text, timestamp '2024-09-01 00:00:00'
        ) s
        where s.watermark > :since
        $sql$
    );
    call deltaplan_test.eq('null pk keys', deltaplan_test.key_count(), '3');
    call deltaplan.prepare_batches(1, false);
    if not deltaplan.next_batch() then
        call deltaplan_test.fail('null pk', 'missing first batch');
    end if;
    select pk_2, pk_2 is null into l_pk2, l_null from deltaplan_batch;
    if not l_null then
        call deltaplan_test.fail('null pk', 'first batch pk_2 was [' || coalesce(l_pk2, 'null') || ']');
    end if;
    call deltaplan.finish_batch();
    if not deltaplan.next_batch() then
        call deltaplan_test.fail('null pk', 'missing second batch');
    end if;
    select pk_2 into l_pk2 from deltaplan_batch;
    call deltaplan_test.eq('empty pk2', l_pk2, '');
    call deltaplan.finish_batch();
    if not deltaplan.next_batch() then
        call deltaplan_test.fail('null pk', 'missing third batch');
    end if;
    select pk_2 into l_pk2 from deltaplan_batch;
    call deltaplan_test.eq('text pk2', l_pk2, 'x');
    call deltaplan.finish_batch();
    call deltaplan.finalize();
    call deltaplan_test.pass('null_pk_parts_stay_distinct');

    -- Two sources, one business key: keyset has one row, keys has two.
    call deltaplan_test.reset();
    call deltaplan_test.add_row('inc_test_a', 'a', 1, c_noon);
    call deltaplan_test.add_row('inc_test_b', 'a', 2, c_noon);
    call deltaplan_test.capture_both();
    select count(*)::integer into l_cnt
    from deltaplan_keys
    where target_table = 'inc_test_tgt' and data_segment = 'all';
    call deltaplan_test.eq('two source rows', l_cnt::text, '2');
    select count(*)::integer into l_cnt
    from deltaplan_keyset
    where target_table = 'inc_test_tgt' and data_segment = 'all';
    call deltaplan_test.eq('two source keyset', l_cnt::text, '1');
    call deltaplan.finalize();
    call deltaplan_test.pass('keyset_is_distinct');

    -- An empty capture leaves the watermark where it was.
    call deltaplan_test.reset();
    call deltaplan_test.add_row('inc_test_a', 'a', 1, c_noon);
    call deltaplan_test.capture_source('inc_test_a');
    call deltaplan.finalize();
    call deltaplan.initialize('inc_test_tgt', 'all', 0);
    call deltaplan_test.capture_source('inc_test_a');
    call deltaplan_test.eq('empty keys', deltaplan_test.key_count(), '0');
    call deltaplan.finalize();
    call deltaplan_test.eq('empty wm', deltaplan_test.wm('inc_test_a'), '2024-06-01 12:00:00');
    call deltaplan_test.pass('empty_delta_keeps_watermark');

    call deltaplan_test.reset();
    call deltaplan.finalize();
    call deltaplan_test.expect_dp(
        'guard init', 'DP-20001',
        'call deltaplan_test.capture_source(''inc_test_a'')'
    );
    call deltaplan_test.expect_dp(
        'guard lookback', 'DP-20002',
        'call deltaplan.initialize(''inc_test_tgt'', ''all'', -1)'
    );
    call deltaplan_test.expect_dp(
        'guard target', 'DP-20006',
        'call deltaplan.initialize(null)'
    );
    call deltaplan.initialize('inc_test_tgt', 'all', 0);
    call deltaplan_test.expect_dp(
        'guard since missing', 'DP-20015',
        'call deltaplan.capture_delta(''inc_test_a'', ''select 1'')'
    );
    call deltaplan_test.expect_dp(
        'guard since twice', 'DP-20015',
        'call deltaplan.capture_delta(''inc_test_a'', ''select 1 where :since > :since'')'
    );
    call deltaplan_test.expect_dp(
        'guard source', 'DP-20006',
        'call deltaplan.capture_delta(null, ''select 1 where 1 > :since'')'
    );
    call deltaplan_test.expect_dp(
        'guard batch 0', 'DP-20003',
        'call deltaplan.prepare_batches(0)'
    );
    call deltaplan_test.expect_dp(
        'guard batch fraction', 'DP-20003',
        'call deltaplan.prepare_batches(1.5)'
    );
    begin
        call deltaplan.capture_delta(
            'inc_test_a',
            $sql$
            select null::text as pk_1,
                   null::text as pk_2,
                   null::text as pk_3,
                   timestamp '2024-07-01' as watermark
            where timestamp '2024-07-01' > :since
            $sql$
        );
        call deltaplan_test.fail('null pk_1', 'insert was accepted');
    exception
        when not_null_violation then
            null;
    end;
    call deltaplan_test.pass('capture_guards');

    raise notice 'deltaplan_test_edges: passed';
end;
$$;
