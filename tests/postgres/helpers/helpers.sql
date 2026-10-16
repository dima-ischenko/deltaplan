-- Shared fixture helpers. Cases live in tests/postgres/cases/.
create schema if not exists dwa_test;

create or replace procedure dwa_test.fail(p_test text, p_detail text)
language plpgsql as $$
begin
    raise exception '%: %', p_test, p_detail;
end;
$$;

create or replace procedure dwa_test.eq(p_test text, p_got text, p_exp text)
language plpgsql as $$
begin
    if p_got = p_exp or (p_got is null and p_exp is null) then
        return;
    end if;
    call dwa_test.fail(
        p_test,
        'expected [' || coalesce(p_exp, 'null') || '] got [' || coalesce(p_got, 'null') || ']'
    );
end;
$$;

create or replace procedure dwa_test.pass(p_test text)
language plpgsql as $$
begin
    raise notice 'ok %', p_test;
end;
$$;

-- p_sql is one statement that must raise DWA-xxxxx. It must not commit.
create or replace procedure dwa_test.expect_dwa(p_test text, p_code text, p_sql text)
language plpgsql as $$
begin
    execute p_sql;
    call dwa_test.fail(p_test, 'expected ' || p_code);
exception
    when others then
        if position(p_code in sqlerrm) = 0 then
            raise;
        end if;
end;
$$;

create or replace procedure dwa_test.reset()
language plpgsql as $$
begin
    set local search_path = pg_temp, lib, public;
    perform initialize(p_target_table => 'inc_test_tgt', p_data_slice => 'all', p_lookback_hours => 0);
    delete from dwa_keys_tmp;
    delete from dwa_batch_tmp;
    delete from dwa_log;
    delete from dwa_watermark
    where target_table in ('inc_test_tgt', 'other_tgt');
    delete from inc_test_a;
    delete from inc_test_b;
    delete from inc_test_tgt;
    delete from inc_test_expect;
    delete from inc_test_seen;
    commit;
end;
$$;

create or replace procedure dwa_test.add_row(
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

create or replace procedure dwa_test.capture_source(p_table text)
language plpgsql as $$
begin
    perform capture_delta(
        p_source_table => p_table,
        p_sql => format(
            'select id as pk_1, updated_at as watermark from %I where updated_at > :since',
            p_table
        )
    );
end;
$$;

create or replace procedure dwa_test.capture_both()
language plpgsql as $$
begin
    call dwa_test.capture_source('inc_test_a');
    call dwa_test.capture_source('inc_test_b');
end;
$$;

-- UPDATE then INSERT, not MERGE: Greenplum 7 has no MERGE.
create or replace procedure dwa_test.merge_all()
language plpgsql
set search_path = pg_temp, lib, public as $$
begin
    update inc_test_tgt t
    set amount = s.amount,
        touch = t.touch + 1
    from (
        select k.pk_1 as id,
               coalesce(max(a.amount), 0) + coalesce(max(b.amount), 0) as amount
        from dwa_keys_tmp k
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
        from dwa_keys_tmp k
        left join inc_test_a a on a.id = k.pk_1
        left join inc_test_b b on b.id = k.pk_1
        group by k.pk_1
    ) s
    where not exists (
        select 1 from inc_test_tgt t where t.id = s.id
    );
end;
$$;

create or replace procedure dwa_test.merge_batch()
language plpgsql
set search_path = pg_temp, lib, public as $$
begin
    update inc_test_tgt t
    set amount = s.amount,
        touch = t.touch + 1
    from (
        select k.pk_1 as id,
               coalesce(max(a.amount), 0) + coalesce(max(b.amount), 0) as amount
        from dwa_batch_tmp k
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
        from dwa_batch_tmp k
        left join inc_test_a a on a.id = k.pk_1
        left join inc_test_b b on b.id = k.pk_1
        group by k.pk_1
    ) s
    where not exists (
        select 1 from inc_test_tgt t where t.id = s.id
    );
end;
$$;

create or replace function dwa_test.key_count()
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
        from dwa_keys_tmp
    ) k;
    return l_cnt::text;
end;
$$;

create or replace function dwa_test.wm(p_source text)
returns text
language plpgsql stable as $$
declare
    l_value timestamp;
begin
    select watermark
    into l_value
    from dwa_watermark
    where target_table = 'inc_test_tgt'
      and data_slice = 'all'
      and source_table = p_source;
    if not found then
        return null;
    end if;
    return to_char(l_value, 'YYYY-MM-DD HH24:MI:SS');
end;
$$;

create or replace function dwa_test.tgt_state()
returns text
language sql stable as $$
    select string_agg(id || ':' || amount || ':' || touch, ',' order by id)
    from inc_test_tgt;
$$;

create or replace function dwa_test.ids_in_batch()
returns text
language plpgsql stable
set search_path = pg_temp, lib, public as $$
begin
    return (
        select string_agg(pk_1, ',' order by pk_1)
        from dwa_batch_tmp
    );
end;
$$;

create or replace function dwa_test.seen(p_batch numeric)
returns text
language sql stable as $$
    select string_agg(id, ',' order by id)
    from inc_test_seen
    where batch_no = p_batch;
$$;

create or replace function dwa_test.tracking_count(p_target text)
returns text
language sql stable as $$
    select count(*)::integer::text
    from dwa_watermark
    where target_table = p_target;
$$;

-- No SET clause on this procedure: a SET attribute forbids COMMIT/ROLLBACK,
-- and reset() must commit when called from here.
create or replace procedure dwa_test.volume(p_rows integer)
language plpgsql as $$
declare
    l_name  text := 'volume_' || p_rows::text;
    l_cnt   bigint;
    l_sum   numeric;
    l_tmin  numeric;
    l_tmax  numeric;
    l_touch numeric;
    c_t1    constant timestamp := timestamp '2024-01-15 10:00:00';
    c_t2    constant timestamp := timestamp '2024-02-01 00:00:00';
begin
    set local search_path = pg_temp, lib, public;
    call dwa_test.reset();

    insert into inc_test_a (id, amount, updated_at)
    select i::text, 1, c_t1
    from generate_series(1, p_rows) i;

    call dwa_test.capture_source('inc_test_a');
    call dwa_test.eq(l_name || ' keys', dwa_test.key_count(), p_rows::text);
    call dwa_test.merge_all();

    select count(*), sum(amount), min(touch), max(touch)
    into l_cnt, l_sum, l_tmin, l_tmax
    from inc_test_tgt;
    call dwa_test.eq(l_name || ' tgt count', l_cnt::text, p_rows::text);
    call dwa_test.eq(l_name || ' tgt sum', l_sum::bigint::text, p_rows::text);
    call dwa_test.eq(l_name || ' tgt touch', l_tmin::bigint::text || ':' || l_tmax::bigint::text, '1:1');

    perform finalize();
    call dwa_test.eq(l_name || ' wm', dwa_test.wm('inc_test_a'), '2024-01-15 10:00:00');

    perform initialize(p_target_table => 'inc_test_tgt', p_data_slice => 'all', p_lookback_hours => 0);
    call dwa_test.capture_source('inc_test_a');
    call dwa_test.eq(l_name || ' second keys', dwa_test.key_count(), '0');
    call dwa_test.merge_all();
    perform finalize();
    select count(*) into l_cnt from inc_test_tgt;
    call dwa_test.eq(l_name || ' second tgt count', l_cnt::text, p_rows::text);

    update inc_test_a
    set amount     = 2,
        updated_at = c_t2
    where id in ('1', (p_rows / 2)::text, p_rows::text);

    perform initialize(p_target_table => 'inc_test_tgt', p_data_slice => 'all', p_lookback_hours => 0);
    call dwa_test.capture_source('inc_test_a');
    call dwa_test.eq(l_name || ' delta keys', dwa_test.key_count(), '3');
    call dwa_test.merge_all();
    perform finalize();

    select count(*), sum(amount), min(touch), max(touch)
    into l_cnt, l_sum, l_tmin, l_tmax
    from inc_test_tgt;
    call dwa_test.eq(l_name || ' delta count', l_cnt::text, p_rows::text);
    call dwa_test.eq(l_name || ' delta sum', l_sum::bigint::text, (p_rows + 3)::text);
    call dwa_test.eq(l_name || ' delta touch', l_tmin::bigint::text || ':' || l_tmax::bigint::text, '1:2');

    select touch into l_touch from inc_test_tgt where id = '1';
    call dwa_test.eq(l_name || ' delta row', l_touch::bigint::text, '2');
    call dwa_test.eq(l_name || ' delta wm', dwa_test.wm('inc_test_a'), '2024-02-01 00:00:00');
    call dwa_test.pass(l_name);
end;
$$;

