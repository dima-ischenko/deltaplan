-- Fixture helpers for the pgTAP suite. Assertions live in deltaplan_tap.sql.

create schema if not exists deltaplan_test;

create or replace procedure deltaplan_test.reset()
language plpgsql as $$
begin
    set search_path = pg_temp, public;
    perform deltaplan.initialize('inc_test_tgt', 'all', 0);
    delete from deltaplan_keys_tmp;
    delete from deltaplan_batch_tmp;
    delete from deltaplan_watermark
    where target_table in ('inc_test_tgt', 'other_tgt');
    delete from inc_test_a;
    delete from inc_test_b;
    delete from inc_test_tgt;
    delete from inc_test_expect;
    delete from inc_test_seen;
    commit;
end;
$$;

create or replace procedure deltaplan_test.add_row(
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

create or replace function deltaplan_test.pk(p_n integer)
returns text
language sql immutable as $$
    select lpad(p_n::text, 5, '0');
$$;

create or replace procedure deltaplan_test.load_a(
    p_from integer, p_to integer, p_at timestamp, p_amount numeric default null
)
language plpgsql as $$
begin
    insert into inc_test_a (id, amount, updated_at)
    select lpad(g::text, 5, '0'),
           coalesce(p_amount, g),
           p_at
    from generate_series(p_from, p_to) g;
end;
$$;

create or replace procedure deltaplan_test.load_b(
    p_from integer, p_to integer, p_at timestamp
)
language plpgsql as $$
begin
    insert into inc_test_b (id, amount, updated_at)
    select lpad(g::text, 5, '0'), 1, p_at
    from generate_series(p_from, p_to) g;
end;
$$;

create or replace procedure deltaplan_test.capture_source(p_table text)
language plpgsql as $$
begin
    perform deltaplan.capture_delta(
        p_table,
        format(
            'select id as pk_1, null::text as pk_2, null::text as pk_3, '
            || 'updated_at as watermark from %I where updated_at > :since',
            p_table
        )
    );
end;
$$;

create or replace procedure deltaplan_test.capture_both()
language plpgsql as $$
begin
    call deltaplan_test.capture_source('inc_test_a');
    call deltaplan_test.capture_source('inc_test_b');
end;
$$;

-- UPDATE then INSERT, not MERGE: Greenplum 7 has no MERGE.
create or replace procedure deltaplan_test.merge_all()
language plpgsql
set search_path = pg_temp, public as $$
begin
    update inc_test_tgt t
    set amount = s.amount,
        touch = t.touch + 1
    from (
        select k.pk_1 as id,
               coalesce(max(a.amount), 0) + coalesce(max(b.amount), 0) as amount
        from deltaplan_keys_tmp k
        left join inc_test_a a on a.id = k.pk_1
        left join inc_test_b b on b.id = k.pk_1
        where k.target_table = deltaplan.get_target_table()
          and k.data_segment = deltaplan.get_data_segment()
        group by k.pk_1
    ) s
    where t.id = s.id;

    insert into inc_test_tgt (id, amount, touch)
    select s.id, s.amount, 1
    from (
        select k.pk_1 as id,
               coalesce(max(a.amount), 0) + coalesce(max(b.amount), 0) as amount
        from deltaplan_keys_tmp k
        left join inc_test_a a on a.id = k.pk_1
        left join inc_test_b b on b.id = k.pk_1
        where k.target_table = deltaplan.get_target_table()
          and k.data_segment = deltaplan.get_data_segment()
        group by k.pk_1
    ) s
    where not exists (
        select 1 from inc_test_tgt t where t.id = s.id
    );
end;
$$;

create or replace procedure deltaplan_test.merge_batch()
language plpgsql
set search_path = pg_temp, public as $$
begin
    update inc_test_tgt t
    set amount = s.amount,
        touch = t.touch + 1
    from (
        select k.pk_1 as id,
               coalesce(max(a.amount), 0) + coalesce(max(b.amount), 0) as amount
        from deltaplan_batch_tmp k
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
        from deltaplan_batch_tmp k
        left join inc_test_a a on a.id = k.pk_1
        left join inc_test_b b on b.id = k.pk_1
        group by k.pk_1
    ) s
    where not exists (
        select 1 from inc_test_tgt t where t.id = s.id
    );
end;
$$;

create or replace function deltaplan_test.key_count()
returns bigint
language plpgsql stable
set search_path = pg_temp, public as $$
begin
    return (
        select count(*)
        from (
            select distinct pk_1, pk_2, pk_3
            from deltaplan_keys_tmp
            where target_table = 'inc_test_tgt'
              and data_segment = 'all'
        ) k
    );
end;
$$;

create or replace function deltaplan_test.wm(p_source text)
returns text
language plpgsql stable as $$
declare
    l_value timestamp;
begin
    select watermark
    into l_value
    from deltaplan_watermark
    where target_table = 'inc_test_tgt'
      and data_segment = 'all'
      and source_table = p_source;
    if not found then
        return null;
    end if;
    return to_char(l_value, 'YYYY-MM-DD HH24:MI:SS');
end;
$$;

create or replace function deltaplan_test.tgt_state()
returns text
language sql stable as $$
    select string_agg(id || ':' || amount || ':' || touch, ',' order by id)
    from inc_test_tgt;
$$;

create or replace function deltaplan_test.tgt_count()
returns bigint
language sql stable as $$
    select count(*) from inc_test_tgt;
$$;

create or replace function deltaplan_test.tgt_sum_amount()
returns bigint
language sql stable as $$
    select coalesce(sum(amount), 0)::bigint from inc_test_tgt;
$$;

create or replace function deltaplan_test.tgt_cell(p_id text)
returns text
language plpgsql stable as $$
declare
    l_value text;
begin
    select amount::text || ':' || touch::text
    into l_value
    from inc_test_tgt
    where id = p_id;
    return l_value;
end;
$$;

create or replace function deltaplan_test.batch_count()
returns bigint
language plpgsql stable
set search_path = pg_temp, public as $$
begin
    return (select count(*) from deltaplan_batch_tmp);
end;
$$;

create or replace function deltaplan_test.batch_lo()
returns text
language plpgsql stable
set search_path = pg_temp, public as $$
begin
    return (select min(pk_1) from deltaplan_batch_tmp);
end;
$$;

create or replace function deltaplan_test.batch_hi()
returns text
language plpgsql stable
set search_path = pg_temp, public as $$
begin
    return (select max(pk_1) from deltaplan_batch_tmp);
end;
$$;

create or replace function deltaplan_test.tracking_count(p_target text)
returns bigint
language sql stable as $$
    select count(*) from deltaplan_watermark where target_table = p_target;
$$;
