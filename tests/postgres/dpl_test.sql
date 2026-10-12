-- Same checks as tests/oracle/pkg_dpl_test.sql.
-- The runner is a procedure so it can commit and roll back at the same points.
-- Call it from the top level:  call dpl_test.run();

create schema if not exists dpl_test;

create or replace procedure dpl_test.fail(p_test text, p_detail text)
language plpgsql as $$
begin
    raise exception '%: %', p_test, p_detail;
end;
$$;

create or replace procedure dpl_test.eq(p_test text, p_got text, p_exp text)
language plpgsql as $$
begin
    if p_got = p_exp or (p_got is null and p_exp is null) then
        return;
    end if;
    call dpl_test.fail(
        p_test,
        'expected [' || coalesce(p_exp, 'null') || '] got [' || coalesce(p_got, 'null') || ']'
    );
end;
$$;

create or replace procedure dpl_test.pass(p_test text)
language plpgsql as $$
begin
    raise notice 'ok %', p_test;
end;
$$;

-- p_sql is one statement that must raise DP-xxxxx. It must not commit.
create or replace procedure dpl_test.expect_dp(p_test text, p_code text, p_sql text)
language plpgsql as $$
begin
    execute p_sql;
    call dpl_test.fail(p_test, 'expected ' || p_code);
exception
    when others then
        if position(p_code in sqlerrm) = 0 then
            raise;
        end if;
end;
$$;

create or replace procedure dpl_test.reset()
language plpgsql as $$
begin
    set search_path = pg_temp, lib, public;
    perform initialize('inc_test_tgt', 'all', 0);
    delete from dpl_keys_tmp;
    delete from dpl_batch_tmp;
    delete from dpl_watermark
    where target_table in ('inc_test_tgt', 'other_tgt');
    delete from inc_test_a;
    delete from inc_test_b;
    delete from inc_test_tgt;
    delete from inc_test_expect;
    delete from inc_test_seen;
    commit;
end;
$$;

create or replace procedure dpl_test.add_row(
    p_table text, p_id text, p_amount numeric, p_at timestamp
)
language plpgsql as $$
begin
    execute format(
        'insert into %I (id, amount, updated_at) values ($1, $2, $3)',
        p_table
    ) using p_id, p_amount, p_at;
end;
$$;

create or replace procedure dpl_test.capture_source(p_table text)
language plpgsql as $$
begin
    perform capture_delta(
        p_table,
        format(
            'select id as pk_1, null::text as pk_2, null::text as pk_3, '
            || 'updated_at as watermark from %I where updated_at > :since',
            p_table
        )
    );
end;
$$;

create or replace procedure dpl_test.capture_both()
language plpgsql as $$
begin
    call dpl_test.capture_source('inc_test_a');
    call dpl_test.capture_source('inc_test_b');
end;
$$;

-- UPDATE then INSERT, not MERGE: Greenplum 7 has no MERGE.
create or replace procedure dpl_test.merge_all()
language plpgsql
set search_path = pg_temp, lib, public as $$
begin
    update inc_test_tgt t
    set amount = s.amount,
        touch = t.touch + 1
    from (
        select k.pk_1 as id,
               coalesce(max(a.amount), 0) + coalesce(max(b.amount), 0) as amount
        from dpl_keys_tmp k
        left join inc_test_a a on a.id = k.pk_1
        left join inc_test_b b on b.id = k.pk_1
        where k.target_table = get_target_table()
          and k.data_segment = get_data_segment()
        group by k.pk_1
    ) s
    where t.id = s.id;

    insert into inc_test_tgt (id, amount, touch)
    select s.id, s.amount, 1
    from (
        select k.pk_1 as id,
               coalesce(max(a.amount), 0) + coalesce(max(b.amount), 0) as amount
        from dpl_keys_tmp k
        left join inc_test_a a on a.id = k.pk_1
        left join inc_test_b b on b.id = k.pk_1
        where k.target_table = get_target_table()
          and k.data_segment = get_data_segment()
        group by k.pk_1
    ) s
    where not exists (
        select 1 from inc_test_tgt t where t.id = s.id
    );
end;
$$;

create or replace procedure dpl_test.merge_batch()
language plpgsql
set search_path = pg_temp, lib, public as $$
begin
    update inc_test_tgt t
    set amount = s.amount,
        touch = t.touch + 1
    from (
        select k.pk_1 as id,
               coalesce(max(a.amount), 0) + coalesce(max(b.amount), 0) as amount
        from dpl_batch_tmp k
        left join inc_test_a a on a.id = k.pk_1
        left join inc_test_b b on b.id = k.pk_1
        group by k.pk_1
    ) s
    where t.id = s.id;

    insert into inc_test_tgt (id, amount, touch)
    select s.id, s.amount, 1
    from (
        select k.pk_1 as id,
               coalesce(max(a.amount), 0) + coalesce(max(b.amount), 0) as amount
        from dpl_batch_tmp k
        left join inc_test_a a on a.id = k.pk_1
        left join inc_test_b b on b.id = k.pk_1
        group by k.pk_1
    ) s
    where not exists (
        select 1 from inc_test_tgt t where t.id = s.id
    );
end;
$$;

create or replace function dpl_test.key_count()
returns text
language plpgsql stable
set search_path = pg_temp, lib, public as $$
declare
    l_cnt integer;
begin
    select count(*)::integer
    into l_cnt
    from (
        select distinct pk_1, pk_2, pk_3
        from dpl_keys_tmp
        where target_table = 'inc_test_tgt'
          and data_segment = 'all'
    ) k;
    return l_cnt::text;
end;
$$;

create or replace function dpl_test.wm(p_source text)
returns text
language plpgsql stable as $$
declare
    l_value timestamp;
begin
    select watermark
    into l_value
    from dpl_watermark
    where target_table = 'inc_test_tgt'
      and data_segment = 'all'
      and source_table = p_source;
    if not found then
        return null;
    end if;
    return to_char(l_value, 'YYYY-MM-DD HH24:MI:SS');
end;
$$;

create or replace function dpl_test.tgt_state()
returns text
language sql stable as $$
    select string_agg(id || ':' || amount || ':' || touch, ',' order by id)
    from inc_test_tgt;
$$;

create or replace function dpl_test.ids_in_batch()
returns text
language plpgsql stable
set search_path = pg_temp, lib, public as $$
begin
    return (
        select string_agg(pk_1, ',' order by pk_1)
        from dpl_batch_tmp
    );
end;
$$;

create or replace function dpl_test.seen(p_batch numeric)
returns text
language sql stable as $$
    select string_agg(id, ',' order by id)
    from inc_test_seen
    where batch_no = p_batch;
$$;

create or replace function dpl_test.tracking_count(p_target text)
returns text
language sql stable as $$
    select count(*)::integer::text
    from dpl_watermark
    where target_table = p_target;
$$;

create or replace procedure dpl_test.run()
language plpgsql as $$
declare
    c_t1   constant timestamp := timestamp '2024-01-15 10:00:00';
    c_t2   constant timestamp := timestamp '2024-02-01 00:00:00';
    c_noon constant timestamp := timestamp '2024-06-01 12:00:00';
    l_step integer;
    l_no   numeric;
    l_ids  text;
    l_wm_a text;
    l_wm_b text;
    l_diff integer;
    l_rows integer;
    l_temp integer;
begin
    -- static, no batches
    call dpl_test.reset();
    call dpl_test.add_row('inc_test_a', '1', 10, c_t1);
    call dpl_test.add_row('inc_test_a', '2', 20, c_t1);
    call dpl_test.add_row('inc_test_b', '2', 5, c_t1);
    call dpl_test.add_row('inc_test_b', '3', 7, c_t1);
    call dpl_test.capture_both();

    insert into dpl_keys_tmp (
        target_table, data_segment, source_table,
        pk_1, pk_2, pk_3, watermark
    ) values (
        'other_tgt', 'all', 'inc_test_a',
        'z', null, null, c_t2
    );

    call dpl_test.eq('static keys', dpl_test.key_count(), '3');
    call dpl_test.eq('static batch no', get_batch_no()::text, null);
    call dpl_test.merge_all();
    call dpl_test.eq('static tgt', dpl_test.tgt_state(), '1:10:1,2:25:1,3:7:1');
    perform finalize();
    call dpl_test.eq('static wm a', dpl_test.wm('inc_test_a'), '2024-01-15 10:00:00');
    call dpl_test.eq('static wm b', dpl_test.wm('inc_test_b'), '2024-01-15 10:00:00');
    call dpl_test.eq('static other tracking', dpl_test.tracking_count('other_tgt'), '0');
    call dpl_test.eq('static closed', get_target_table(), null);

    perform initialize('inc_test_tgt', 'all', 0);
    call dpl_test.capture_both();
    call dpl_test.eq('static second keys', dpl_test.key_count(), '0');
    call dpl_test.merge_all();
    perform finalize();
    call dpl_test.eq('static second wm a', dpl_test.wm('inc_test_a'), '2024-01-15 10:00:00');
    call dpl_test.eq('static second tgt', dpl_test.tgt_state(), '1:10:1,2:25:1,3:7:1');

    update inc_test_a
    set amount = 50,
        updated_at = c_t2
    where id = '2';

    perform initialize('inc_test_tgt', 'all', 0);
    call dpl_test.capture_both();
    call dpl_test.eq('static delta keys', dpl_test.key_count(), '1');
    call dpl_test.merge_all();
    perform finalize();
    call dpl_test.eq('static delta tgt', dpl_test.tgt_state(), '1:10:1,2:55:2,3:7:1');
    call dpl_test.eq('static delta wm a', dpl_test.wm('inc_test_a'), '2024-02-01 00:00:00');
    call dpl_test.eq('static delta wm b', dpl_test.wm('inc_test_b'), '2024-01-15 10:00:00');
    call dpl_test.pass('static_without_batches');

    -- lookback: watermark 12:00 minus 2 hours keeps 11:00 and 13:00 only
    call dpl_test.reset();
    insert into dpl_watermark (target_table, data_segment, source_table, watermark, updated_at)
    values ('inc_test_tgt', 'all', 'inc_test_a', c_noon, clock_timestamp()::timestamp);
    call dpl_test.add_row('inc_test_a', 'a', 1, timestamp '2024-06-01 09:00:00');
    call dpl_test.add_row('inc_test_a', 'd', 1, timestamp '2024-06-01 10:00:00');
    call dpl_test.add_row('inc_test_a', 'b', 1, timestamp '2024-06-01 11:00:00');
    call dpl_test.add_row('inc_test_a', 'c', 1, timestamp '2024-06-01 13:00:00');
    perform initialize('inc_test_tgt', 'all', 2);
    call dpl_test.capture_source('inc_test_a');
    call dpl_test.eq('lookback keys', dpl_test.key_count(), '2');
    call dpl_test.merge_all();
    call dpl_test.eq('lookback tgt', dpl_test.tgt_state(), 'b:1:1,c:1:1');
    perform finalize();
    call dpl_test.eq('lookback wm', dpl_test.wm('inc_test_a'), '2024-06-01 13:00:00');
    call dpl_test.pass('lookback_window');

    -- batches of two, lexical order a,b then c,d then e
    call dpl_test.reset();
    call dpl_test.add_row('inc_test_a', 'a', 1, c_t1);
    call dpl_test.add_row('inc_test_a', 'b', 2, c_t1);
    call dpl_test.add_row('inc_test_a', 'c', 3, c_t1);
    call dpl_test.add_row('inc_test_a', 'd', 4, c_t1);
    call dpl_test.add_row('inc_test_a', 'e', 5, c_t1);
    call dpl_test.capture_source('inc_test_a');
    perform prepare_batches(2);
    l_step := 0;
    while next_batch() loop
        l_step := l_step + 1;
        l_no := get_batch_no();
        insert into inc_test_seen (batch_no, id)
        select l_no, pk_1 from dpl_batch_tmp;
        call dpl_test.merge_batch();
        if l_step = 1 then
            call dpl_test.eq('open batch', l_no::integer::text, '1');
            call dpl_test.eq('open keys', dpl_test.ids_in_batch(), 'a,b');
            call dpl_test.eq('open tgt', dpl_test.tgt_state(), 'a:1:1,b:2:1');
            call dpl_test.eq('open wm', dpl_test.wm('inc_test_a'), null);
        end if;
        perform finish_batch();
    end loop;
    call dpl_test.eq('batches', l_step::text, '3');
    call dpl_test.eq('seen 1', dpl_test.seen(1), 'a,b');
    call dpl_test.eq('seen 2', dpl_test.seen(2), 'c,d');
    call dpl_test.eq('seen 3', dpl_test.seen(3), 'e');
    call dpl_test.eq('batch tgt before finalize', dpl_test.tgt_state(), 'a:1:1,b:2:1,c:3:1,d:4:1,e:5:1');
    call dpl_test.eq('batch wm before finalize', dpl_test.wm('inc_test_a'), null);
    perform finalize();
    call dpl_test.eq('batch wm', dpl_test.wm('inc_test_a'), '2024-01-15 10:00:00');
    call dpl_test.pass('static_batches');

    -- one key per batch matches the static merge
    call dpl_test.reset();
    call dpl_test.add_row('inc_test_a', 'a', 10, c_t1);
    call dpl_test.add_row('inc_test_a', 'b', 20, c_t1);
    call dpl_test.add_row('inc_test_b', 'b', 3, c_t1);
    call dpl_test.add_row('inc_test_b', 'c', 4, c_t1);
    call dpl_test.capture_both();
    call dpl_test.merge_all();
    perform finalize();
    l_wm_a := dpl_test.wm('inc_test_a');
    l_wm_b := dpl_test.wm('inc_test_b');
    delete from inc_test_expect;
    insert into inc_test_expect (id, amount, touch)
    select id, amount, touch from inc_test_tgt;
    delete from inc_test_tgt;
    delete from dpl_watermark where target_table = 'inc_test_tgt';
    commit;

    perform initialize('inc_test_tgt', 'all', 0);
    call dpl_test.capture_both();
    perform prepare_batches(1);
    while next_batch() loop
        call dpl_test.merge_batch();
        perform finish_batch();
    end loop;
    perform finalize();

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
    call dpl_test.eq('same rows', l_diff::text, '0');
    call dpl_test.eq('same wm a', dpl_test.wm('inc_test_a'), l_wm_a);
    call dpl_test.eq('same wm b', dpl_test.wm('inc_test_b'), l_wm_b);
    call dpl_test.pass('same_result');

    -- rollback of an open batch returns the same keys
    call dpl_test.reset();
    call dpl_test.add_row('inc_test_a', 'a', 1, c_t1);
    call dpl_test.add_row('inc_test_a', 'b', 2, c_t1);
    call dpl_test.add_row('inc_test_a', 'c', 3, c_t1);
    call dpl_test.capture_source('inc_test_a');
    perform prepare_batches(2);
    -- The engine does not commit. Persist the first batch so a later
    -- rollback of the open batch can resume.
    commit;
    if not next_batch() then
        call dpl_test.fail('resume', 'missing first batch');
    end if;
    call dpl_test.merge_batch();
    perform finish_batch();
    commit;
    call dpl_test.eq('resume after first', dpl_test.tgt_state(), 'a:1:1,b:2:1');
    if not next_batch() then
        call dpl_test.fail('resume', 'missing second batch');
    end if;
    l_no := get_batch_no();
    l_ids := dpl_test.ids_in_batch();
    call dpl_test.merge_batch();
    rollback;
    call dpl_test.eq('resume rolled back', dpl_test.tgt_state(), 'a:1:1,b:2:1');
    if not next_batch() then
        call dpl_test.fail('resume', 'batch was not reopened');
    end if;
    call dpl_test.eq('resume batch no', get_batch_no()::integer::text, l_no::integer::text);
    call dpl_test.eq('resume keys', dpl_test.ids_in_batch(), l_ids);
    call dpl_test.merge_batch();
    perform finish_batch();
    if next_batch() then
        call dpl_test.fail('resume', 'unexpected extra batch');
    end if;
    call dpl_test.eq('resume wm still old', dpl_test.wm('inc_test_a'), null);
    perform finalize();
    call dpl_test.eq('resume tgt', dpl_test.tgt_state(), 'a:1:1,b:2:1,c:3:1');
    call dpl_test.eq('resume wm', dpl_test.wm('inc_test_a'), '2024-01-15 10:00:00');
    call dpl_test.pass('resume_same_batch');

    -- guards
    call dpl_test.reset();
    call dpl_test.add_row('inc_test_a', 'a', 1, c_t1);
    call dpl_test.add_row('inc_test_a', 'b', 1, c_t1);
    call dpl_test.add_row('inc_test_a', 'c', 1, c_t1);
    call dpl_test.capture_source('inc_test_a');
    perform prepare_batches(2);
    if not next_batch() then
        call dpl_test.fail('guard finalize', 'missing batch');
    end if;
    call dpl_test.expect_dp('guard finalize', 'DP-20005', 'select finalize()');
    call dpl_test.merge_batch();
    perform finish_batch();
    while next_batch() loop
        call dpl_test.merge_batch();
        perform finish_batch();
    end loop;
    perform finalize();
    call dpl_test.eq('guard tgt', dpl_test.tgt_state(), 'a:1:1,b:1:1,c:1:1');

    call dpl_test.reset();
    call dpl_test.add_row('inc_test_a', 'a', 1, c_t1);
    call dpl_test.add_row('inc_test_a', 'b', 1, c_t1);
    call dpl_test.capture_source('inc_test_a');
    perform prepare_batches(1);
    if not next_batch() then
        call dpl_test.fail('guard next', 'missing batch');
    end if;
    call dpl_test.expect_dp('guard next', 'DP-20014', 'select next_batch()');
    call dpl_test.merge_batch();
    perform finish_batch();
    while next_batch() loop
        call dpl_test.merge_batch();
        perform finish_batch();
    end loop;
    perform finalize();

    call dpl_test.reset();
    call dpl_test.add_row('inc_test_a', 'a', 1, c_t1);
    call dpl_test.capture_source('inc_test_a');
    perform prepare_batches(2);
    call dpl_test.expect_dp(
        'guard size', 'DP-20009', 'select prepare_batches(3)'
    );
    call dpl_test.expect_dp(
        'guard capture', 'DP-20013',
        'call dpl_test.capture_source(''inc_test_a'')'
    );
    while next_batch() loop
        call dpl_test.merge_batch();
        perform finish_batch();
    end loop;
    perform finalize();

    call dpl_test.reset();
    call dpl_test.expect_dp('guard no prepare', 'DP-20016', 'select next_batch()');
    call dpl_test.expect_dp('guard no batch', 'DP-20017', 'select finish_batch()');
    call dpl_test.pass('batch_guards');

    -- one primary key from two sources shares one batch
    call dpl_test.reset();
    call dpl_test.add_row('inc_test_a', 'a', 10, c_t1);
    call dpl_test.add_row('inc_test_a', 'b', 20, c_t1);
    call dpl_test.add_row('inc_test_b', 'a', 1, c_t1);
    call dpl_test.add_row('inc_test_b', 'b', 2, c_t1);
    call dpl_test.capture_both();
    perform prepare_batches(10);
    if not next_batch() then
        call dpl_test.fail('one pk', 'missing batch');
    end if;
    select count(*)::integer into l_rows from dpl_batch_tmp;
    select count(*)::integer into l_temp
    from dpl_keys_tmp
    where target_table = 'inc_test_tgt'
      and data_segment = 'all';
    call dpl_test.eq('one pk keys', dpl_test.ids_in_batch(), 'a,b');
    call dpl_test.eq('one pk batch rows', l_rows::text, '2');
    call dpl_test.eq('one pk temp rows', l_temp::text, '4');
    call dpl_test.merge_batch();
    perform finish_batch();
    if next_batch() then
        call dpl_test.fail('one pk', 'second batch');
    end if;
    perform finalize();
    call dpl_test.eq('one pk tgt', dpl_test.tgt_state(), 'a:11:1,b:22:1');
    call dpl_test.pass('one_pk_one_batch');

    -- No commit after the load: rollback drops the target rows and does not
    -- move the watermark. The engine never commits on PostgreSQL.
    call dpl_test.reset();
    call dpl_test.add_row('inc_test_a', 'a', 1, c_t1);
    call dpl_test.add_row('inc_test_a', 'b', 2, c_t1);
    call dpl_test.capture_source('inc_test_a');
    perform prepare_batches(1);
    while next_batch() loop
        call dpl_test.merge_batch();
        perform finish_batch();
    end loop;
    rollback;
    call dpl_test.eq('rollback tgt', dpl_test.tgt_state(), null);
    perform finalize();
    call dpl_test.eq('rollback wm', dpl_test.wm('inc_test_a'), null);
    call dpl_test.pass('rollback_without_commit');

    raise notice 'dpl_test: passed';
end;
$$;
