-- pgTAP suite. Same checks as tests/oracle/pkg_deltaplan_test.sql.
-- The helpers are in schema deltaplan_test. Assertions are pgTAP.

select no_plan();

do $t$
declare
    c_t1     constant timestamp := timestamp '2024-01-15 10:00:00';
    c_t2     constant timestamp := timestamp '2024-02-01 00:00:00';
    c_noon   constant timestamp := timestamp '2024-06-01 12:00:00';
    c_n      constant integer := 10000;
    c_b_from constant integer := 5001;
    c_b_to   constant integer := 15000;
    c_batch  constant integer := 4000;
    l_step integer;
    l_no   numeric;
    l_cnt  bigint;
    l_lo   text;
    l_hi   text;
    l_wm_a text;
    l_wm_b text;
    l_diff integer;
    l_rows bigint;
    l_temp bigint;
    l_seen   bigint;
    l_sum    bigint;
    l_opened boolean;
begin
    l_sum := c_n * (c_n + 1) / 2 + c_n;

    call deltaplan_test.reset();
    call deltaplan_test.load_a(1, c_n, c_t1);
    call deltaplan_test.load_b(c_b_from, c_b_to, c_t1);
    call deltaplan_test.capture_both();

    insert into deltaplan_keys_tmp (
        target_table, data_segment, source_table,
        pk_1, pk_2, pk_3, watermark
    ) values (
        'other_tgt', 'all', 'inc_test_a',
        'z', null, null, c_t2
    );

    perform is(deltaplan_test.key_count(), c_b_to::bigint, 'static keys');
    perform is(deltaplan.get_batch_no()::text, null, 'static batch no');
    call deltaplan_test.merge_all();
    perform is(deltaplan_test.tgt_count(), c_b_to::bigint, 'static tgt count');
    perform is(deltaplan_test.tgt_sum_amount(), l_sum, 'static tgt sum');
    perform is(deltaplan_test.tgt_cell(deltaplan_test.pk(1)), '1:1', 'static lo');
    perform is(
        deltaplan_test.tgt_cell(deltaplan_test.pk(c_b_from)),
        (c_b_from + 1)::text || ':1',
        'static overlap'
    );
    perform is(deltaplan_test.tgt_cell(deltaplan_test.pk(c_b_to)), '1:1', 'static hi');
    perform deltaplan.finalize();
    perform is(deltaplan_test.wm('inc_test_a'), '2024-01-15 10:00:00', 'static wm a');
    perform is(deltaplan_test.wm('inc_test_b'), '2024-01-15 10:00:00', 'static wm b');
    perform is(deltaplan_test.tracking_count('other_tgt'), 0::bigint, 'static other tracking');
    perform is(deltaplan.get_target_table(), null, 'static closed');

    perform deltaplan.initialize('inc_test_tgt', 'all', 0);
    call deltaplan_test.capture_both();
    perform is(deltaplan_test.key_count(), 0::bigint, 'static second keys');
    call deltaplan_test.merge_all();
    perform deltaplan.finalize();
    perform is(deltaplan_test.wm('inc_test_a'), '2024-01-15 10:00:00', 'static second wm a');
    perform is(deltaplan_test.tgt_count(), c_b_to::bigint, 'static second tgt count');
    perform is(
        deltaplan_test.tgt_cell(deltaplan_test.pk(c_b_from)),
        (c_b_from + 1)::text || ':1',
        'static second overlap'
    );

    update inc_test_a
    set amount = 50,
        updated_at = c_t2
    where id = deltaplan_test.pk(c_b_from);

    perform deltaplan.initialize('inc_test_tgt', 'all', 0);
    call deltaplan_test.capture_both();
    perform is(deltaplan_test.key_count(), 1::bigint, 'static delta keys');
    call deltaplan_test.merge_all();
    perform deltaplan.finalize();
    perform is(deltaplan_test.tgt_count(), c_b_to::bigint, 'static delta tgt count');
    perform is(
        deltaplan_test.tgt_cell(deltaplan_test.pk(c_b_from)),
        '51:2',
        'static delta overlap'
    );
    perform is(deltaplan_test.tgt_cell(deltaplan_test.pk(1)), '1:1', 'static delta lo');
    perform is(deltaplan_test.wm('inc_test_a'), '2024-02-01 00:00:00', 'static delta wm a');
    perform is(deltaplan_test.wm('inc_test_b'), '2024-01-15 10:00:00', 'static delta wm b');

    call deltaplan_test.reset();
    insert into deltaplan_watermark (
        target_table, data_segment, source_table, watermark, updated_at
    )
    values ('inc_test_tgt', 'all', 'inc_test_a', c_noon, clock_timestamp()::timestamp);
    call deltaplan_test.load_a(1, 4000, timestamp '2024-06-01 09:00:00', 1);
    call deltaplan_test.load_a(4001, 6000, timestamp '2024-06-01 10:00:00', 1);
    call deltaplan_test.load_a(6001, 9000, timestamp '2024-06-01 11:00:00', 1);
    call deltaplan_test.load_a(9001, c_n, timestamp '2024-06-01 13:00:00', 1);
    perform deltaplan.initialize('inc_test_tgt', 'all', 2);
    call deltaplan_test.capture_source('inc_test_a');
    perform is(deltaplan_test.key_count(), 4000::bigint, 'lookback keys');
    call deltaplan_test.merge_all();
    perform is(deltaplan_test.tgt_count(), 4000::bigint, 'lookback tgt count');
    perform is(deltaplan_test.tgt_cell(deltaplan_test.pk(6001)), '1:1', 'lookback in');
    perform is(deltaplan_test.tgt_cell(deltaplan_test.pk(c_n)), '1:1', 'lookback hi');
    perform is(deltaplan_test.tgt_cell(deltaplan_test.pk(6000)), null, 'lookback excluded');
    perform deltaplan.finalize();
    perform is(deltaplan_test.wm('inc_test_a'), '2024-06-01 13:00:00', 'lookback wm');

    call deltaplan_test.reset();
    call deltaplan_test.load_a(1, c_n, c_t1);
    call deltaplan_test.capture_source('inc_test_a');
    perform deltaplan.prepare_batches(c_batch);
    l_step := 0;
    while deltaplan.next_batch() loop
        l_step := l_step + 1;
        l_no := deltaplan.get_batch_no();
        insert into inc_test_seen (batch_no, id)
        select l_no, pk_1 from deltaplan_batch_tmp;
        call deltaplan_test.merge_batch();
        if l_step = 1 then
            perform is(l_no::integer, 1, 'open batch');
            perform is(deltaplan_test.batch_count(), c_batch::bigint, 'open keys');
            perform is(deltaplan_test.batch_lo(), deltaplan_test.pk(1), 'open lo');
            perform is(deltaplan_test.batch_hi(), deltaplan_test.pk(c_batch), 'open hi');
            perform is(deltaplan_test.tgt_count(), c_batch::bigint, 'open tgt count');
            perform is(deltaplan_test.wm('inc_test_a'), null, 'open wm');
        end if;
        perform deltaplan.finish_batch();
    end loop;
    perform is(l_step, 3, 'batches');
    select count(*) into l_seen from inc_test_seen where batch_no = 1;
    perform is(l_seen, c_batch::bigint, 'seen 1');
    select count(*) into l_seen from inc_test_seen where batch_no = 2;
    perform is(l_seen, c_batch::bigint, 'seen 2');
    select count(*) into l_seen from inc_test_seen where batch_no = 3;
    perform is(l_seen, (c_n - 2 * c_batch)::bigint, 'seen 3');
    perform is(deltaplan_test.tgt_count(), c_n::bigint, 'batch tgt before finalize');
    perform is(deltaplan_test.tgt_cell(deltaplan_test.pk(1)), '1:1', 'batch lo');
    perform is(
        deltaplan_test.tgt_cell(deltaplan_test.pk(c_n)),
        c_n::text || ':1',
        'batch hi'
    );
    perform is(deltaplan_test.wm('inc_test_a'), null, 'batch wm before finalize');
    perform deltaplan.finalize();
    perform is(deltaplan_test.wm('inc_test_a'), '2024-01-15 10:00:00', 'batch wm');

    call deltaplan_test.reset();
    call deltaplan_test.load_a(1, c_n, c_t1);
    call deltaplan_test.load_b(c_b_from, c_b_to, c_t1);
    call deltaplan_test.capture_both();
    call deltaplan_test.merge_all();
    perform deltaplan.finalize();
    l_wm_a := deltaplan_test.wm('inc_test_a');
    l_wm_b := deltaplan_test.wm('inc_test_b');
    delete from inc_test_expect;
    insert into inc_test_expect (id, amount, touch)
    select id, amount, touch from inc_test_tgt;
    delete from inc_test_tgt;
    delete from deltaplan_watermark where target_table = 'inc_test_tgt';
    commit;

    perform deltaplan.initialize('inc_test_tgt', 'all', 0);
    call deltaplan_test.capture_both();
    perform deltaplan.prepare_batches(c_batch);
    while deltaplan.next_batch() loop
        call deltaplan_test.merge_batch();
        perform deltaplan.finish_batch();
    end loop;
    perform deltaplan.finalize();

    select count(*)::integer
    into l_diff
    from (
        select id, amount, touch from inc_test_tgt
        except
        select id, amount, touch from inc_test_expect
        union all
        select id, amount, touch from inc_test_expect
        except
        select id, amount, touch from inc_test_tgt
    ) d;
    perform is(l_diff, 0, 'same rows');
    perform is(deltaplan_test.wm('inc_test_a'), l_wm_a, 'same wm a');
    perform is(deltaplan_test.wm('inc_test_b'), l_wm_b, 'same wm b');

    call deltaplan_test.reset();
    call deltaplan_test.load_a(1, c_n, c_t1);
    call deltaplan_test.capture_source('inc_test_a');
    perform deltaplan.prepare_batches(c_batch);
    -- Persist captured keys and any TAP rows so a later rollback can resume.
    commit;
    perform ok(deltaplan.next_batch(), 'resume first batch');
    call deltaplan_test.merge_batch();
    perform deltaplan.finish_batch();
    commit;
    perform is(deltaplan_test.tgt_count(), c_batch::bigint, 'resume after first');
    commit;
    l_opened := deltaplan.next_batch();
    l_no := deltaplan.get_batch_no();
    l_cnt := deltaplan_test.batch_count();
    l_lo := deltaplan_test.batch_lo();
    l_hi := deltaplan_test.batch_hi();
    call deltaplan_test.merge_batch();
    rollback;
    perform ok(l_opened, 'resume second batch');
    perform is(deltaplan_test.tgt_count(), c_batch::bigint, 'resume rolled back');
    perform ok(deltaplan.next_batch(), 'resume reopened');
    perform is(deltaplan.get_batch_no()::integer, l_no::integer, 'resume batch no');
    perform is(deltaplan_test.batch_count(), l_cnt, 'resume keys');
    perform is(deltaplan_test.batch_lo(), l_lo, 'resume lo');
    perform is(deltaplan_test.batch_hi(), l_hi, 'resume hi');
    call deltaplan_test.merge_batch();
    perform deltaplan.finish_batch();
    perform ok(deltaplan.next_batch(), 'resume third batch');
    call deltaplan_test.merge_batch();
    perform deltaplan.finish_batch();
    perform ok(not deltaplan.next_batch(), 'resume extra batch');
    perform is(deltaplan_test.wm('inc_test_a'), null, 'resume wm still old');
    perform deltaplan.finalize();
    perform is(deltaplan_test.tgt_count(), c_n::bigint, 'resume tgt');
    perform is(deltaplan_test.tgt_cell(deltaplan_test.pk(1)), '1:1', 'resume lo cell');
    perform is(
        deltaplan_test.tgt_cell(deltaplan_test.pk(c_n)),
        c_n::text || ':1',
        'resume hi cell'
    );
    perform is(deltaplan_test.wm('inc_test_a'), '2024-01-15 10:00:00', 'resume wm');

    call deltaplan_test.reset();
    call deltaplan_test.add_row('inc_test_a', 'a', 1, c_t1);
    call deltaplan_test.add_row('inc_test_a', 'b', 1, c_t1);
    call deltaplan_test.add_row('inc_test_a', 'c', 1, c_t1);
    call deltaplan_test.capture_source('inc_test_a');
    perform deltaplan.prepare_batches(2);
    perform ok(deltaplan.next_batch(), 'guard finalize batch');
    perform throws_like('select deltaplan.finalize()', '%DP-20005%', 'guard finalize');
    call deltaplan_test.merge_batch();
    perform deltaplan.finish_batch();
    while deltaplan.next_batch() loop
        call deltaplan_test.merge_batch();
        perform deltaplan.finish_batch();
    end loop;
    perform deltaplan.finalize();
    perform is(deltaplan_test.tgt_state(), 'a:1:1,b:1:1,c:1:1', 'guard tgt');

    call deltaplan_test.reset();
    call deltaplan_test.add_row('inc_test_a', 'a', 1, c_t1);
    call deltaplan_test.add_row('inc_test_a', 'b', 1, c_t1);
    call deltaplan_test.capture_source('inc_test_a');
    perform deltaplan.prepare_batches(1);
    perform ok(deltaplan.next_batch(), 'guard next batch');
    perform throws_like('select deltaplan.next_batch()', '%DP-20014%', 'guard next');
    call deltaplan_test.merge_batch();
    perform deltaplan.finish_batch();
    while deltaplan.next_batch() loop
        call deltaplan_test.merge_batch();
        perform deltaplan.finish_batch();
    end loop;
    perform deltaplan.finalize();

    call deltaplan_test.reset();
    call deltaplan_test.add_row('inc_test_a', 'a', 1, c_t1);
    call deltaplan_test.capture_source('inc_test_a');
    perform deltaplan.prepare_batches(2);
    perform throws_like('select deltaplan.prepare_batches(3)', '%DP-20009%', 'guard size');
    perform throws_like(
        'call deltaplan_test.capture_source(''inc_test_a'')',
        '%DP-20013%',
        'guard capture'
    );
    while deltaplan.next_batch() loop
        call deltaplan_test.merge_batch();
        perform deltaplan.finish_batch();
    end loop;
    perform deltaplan.finalize();

    call deltaplan_test.reset();
    perform throws_like('select deltaplan.next_batch()', '%DP-20016%', 'guard no prepare');
    perform throws_like('select deltaplan.finish_batch()', '%DP-20017%', 'guard no batch');

    call deltaplan_test.reset();
    call deltaplan_test.load_a(1, c_n, c_t1);
    call deltaplan_test.load_b(1, c_n, c_t1);
    call deltaplan_test.capture_both();
    perform deltaplan.prepare_batches(c_n);
    perform ok(deltaplan.next_batch(), 'one pk batch');
    select count(*) into l_rows from deltaplan_batch_tmp;
    select count(*) into l_temp
    from deltaplan_keys_tmp
    where target_table = 'inc_test_tgt'
      and data_segment = 'all';
    perform is(deltaplan_test.batch_count(), c_n::bigint, 'one pk keys');
    perform is(deltaplan_test.batch_lo(), deltaplan_test.pk(1), 'one pk lo');
    perform is(deltaplan_test.batch_hi(), deltaplan_test.pk(c_n), 'one pk hi');
    perform is(l_rows, c_n::bigint, 'one pk batch rows');
    perform is(l_temp, (c_n * 2)::bigint, 'one pk temp rows');
    call deltaplan_test.merge_batch();
    perform deltaplan.finish_batch();
    perform ok(not deltaplan.next_batch(), 'one pk second batch');
    perform deltaplan.finalize();
    perform is(deltaplan_test.tgt_count(), c_n::bigint, 'one pk tgt count');
    perform is(deltaplan_test.tgt_cell(deltaplan_test.pk(1)), '2:1', 'one pk lo cell');
    perform is(
        deltaplan_test.tgt_cell(deltaplan_test.pk(c_n)),
        (c_n + 1)::text || ':1',
        'one pk hi cell'
    );

    call deltaplan_test.reset();
    call deltaplan_test.load_a(1, c_n, c_t1);
    call deltaplan_test.capture_source('inc_test_a');
    perform deltaplan.prepare_batches(c_batch);
    while deltaplan.next_batch() loop
        call deltaplan_test.merge_batch();
        perform deltaplan.finish_batch();
    end loop;
    rollback;
    perform is(deltaplan_test.tgt_state(), null, 'rollback tgt');
    perform deltaplan.finalize();
    perform is(deltaplan_test.wm('inc_test_a'), null, 'rollback wm');
end;
$t$;

select * from finish(true);
