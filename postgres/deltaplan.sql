-- Deltaplan for PostgreSQL 11 or newer, and for Greenplum 7.
-- Greenplum 7 is the first Greenplum release with procedures that commit.
-- The script does not use MERGE: Greenplum has none. A target statement is
-- an UPDATE and an INSERT, or INSERT ... ON CONFLICT where the server has it.
--
-- The calculating session calls deltaplan.initialize, which creates the
-- temporary tables deltaplan_keys and deltaplan_batch. Their names match the
-- Oracle installation, so the target statement can read them unqualified.
-- deltaplan_watermark is permanent and holds the watermark.
-- Column order matches the Oracle tables. See oracle/deltaplan_keys.sql.
--
-- PostgreSQL keeps session flags in deltaplan_session, also temporary.
-- A commit inside prepare_batches or finish_batch persists those flags;
-- a later rollback undoes only the open batch. Call initialize again if
-- that first transaction is rolled back before anything has been committed:
-- the temporary tables are created inside it.

create schema if not exists deltaplan;

drop procedure if exists deltaplan.apply_batches(text, numeric, boolean);
-- CREATE OR REPLACE cannot rename an argument. Earlier builds used oversync_hours.
drop function if exists deltaplan.get_oversync_hours();
drop procedure if exists deltaplan.initialize(text, text, numeric);
drop procedure if exists deltaplan.capture_delta(text, text, numeric);

-- Permanent, so the name is schema-qualified. A role search_path of
-- "$user", public would otherwise create a second copy beside public.
-- On Greenplum the primary key must contain the distribution key, or
-- INSERT ... ON CONFLICT is rejected. target_table is that key.
do $ddl$
declare
    l_distributed text := '';
begin
    if to_regclass('public.deltaplan_watermark') is not null then
        return;
    end if;

    if position('greenplum' in lower(version())) > 0 then
        l_distributed := ' distributed by (target_table)';
    end if;

    execute
        'create table public.deltaplan_watermark (
            target_table    text        not null,
            data_segment    text        not null default ''all'',
            source_table    text        not null,
            watermark       timestamp   not null,
            updated_at      timestamp   not null,
            constraint pk_deltaplan_watermark primary key (target_table, data_segment, source_table)
        )' || l_distributed;
end
$ddl$;

comment on table public.deltaplan_watermark is
    'High-water mark of a finished run. deltaplan.finalize advances it and never moves it backwards.';
comment on column public.deltaplan_watermark.watermark is
    'Greatest source value fully applied for this target, segment and source. The read bound is this value minus the lookback, and that bound is not stored.';
comment on column public.deltaplan_watermark.updated_at is
    'When finalize last wrote this row.';

create or replace procedure deltaplan._ensure_temp()
language plpgsql
set search_path = pg_temp, public as $$
declare
    l_by_id  text := '';
    l_by_pk  text := '';
begin
    -- PostgreSQL rejects DISTRIBUTED BY. Greenplum needs it: the primary key
    -- of deltaplan_session has to contain the distribution key, and the key
    -- tables are distributed by pk_1, the column the calculation joins.
    if position('greenplum' in lower(version())) > 0 then
        l_by_id := ' distributed by (id)';
        l_by_pk := ' distributed by (pk_1)';
    end if;

    execute format($sql$
        create temp table if not exists deltaplan_session (
            id              int primary key,
            target_table    text,
            data_segment    text,
            lookback_hours  numeric,
            batch_no        numeric,
            batch_size      numeric,
            batch_commit    boolean,
            batches_ready   boolean,
            keys_durable    boolean,
            apply_open      boolean,
            constraint ck_deltaplan_session_id check (id = 1)
        ) on commit preserve rows%s
    $sql$, l_by_id);

    execute format($sql$
        create temp table if not exists deltaplan_keys (
            target_table    text        not null,
            data_segment    text        not null,
            source_table    text        not null,
            pk_1            text        not null,
            pk_2            text,
            pk_3            text,
            watermark       timestamp   not null,
            batch_no        numeric,
            batch_done      smallint    not null default 0,
            constraint ck_deltaplan_keys_batch_done check (batch_done in (0, 1))
        ) on commit preserve rows%s
    $sql$, l_by_pk);

    execute format($sql$
        create temp table if not exists deltaplan_batch (
            pk_1            text        not null,
            pk_2            text,
            pk_3            text
        ) on commit delete rows%s
    $sql$, l_by_pk);

    create index if not exists idx_deltaplan_keys_batch
        on deltaplan_keys (target_table, data_segment, batch_no, batch_done);
end;
$$;

create or replace function deltaplan.get_target_table()
returns text
language plpgsql stable
set search_path = pg_temp, public as $$
begin
    if to_regclass('deltaplan_session') is null then
        return null;
    end if;
    return (select target_table from deltaplan_session where id = 1);
end;
$$;

create or replace function deltaplan.get_data_segment()
returns text
language plpgsql stable
set search_path = pg_temp, public as $$
begin
    if to_regclass('deltaplan_session') is null then
        return null;
    end if;
    return (select data_segment from deltaplan_session where id = 1);
end;
$$;

create or replace function deltaplan.get_lookback_hours()
returns numeric
language plpgsql stable
set search_path = pg_temp, public as $$
begin
    if to_regclass('deltaplan_session') is null then
        return null;
    end if;
    return (select lookback_hours from deltaplan_session where id = 1);
end;
$$;

-- The number of the batch that is open, or null when none is.
create or replace function deltaplan.get_batch_no()
returns numeric
language plpgsql stable
set search_path = pg_temp, public as $$
begin
    if to_regclass('deltaplan_session') is null then
        return null;
    end if;
    return (select batch_no from deltaplan_session where id = 1);
end;
$$;

-- These read the session's temporary tables, which do not exist until initialize.
create or replace function deltaplan._unfinished()
returns integer
language plpgsql stable
set search_path = pg_temp, public as $$
declare
    l_left integer;
begin
    select count(distinct batch_no)::integer
    into l_left
    from deltaplan_keys
    where target_table = deltaplan.get_target_table()
      and data_segment = deltaplan.get_data_segment()
      and batch_no is not null
      and batch_done = 0;
    return l_left;
end;
$$;

create or replace function deltaplan._unassigned()
returns integer
language plpgsql stable
set search_path = pg_temp, public as $$
declare
    l_cnt integer;
begin
    select count(*)::integer
    into l_cnt
    from deltaplan_keys
    where target_table = deltaplan.get_target_table()
      and data_segment = deltaplan.get_data_segment()
      and batch_no is null;
    return l_cnt;
end;
$$;

create or replace function deltaplan._batch_total()
returns integer
language plpgsql stable
set search_path = pg_temp, public as $$
declare
    l_cnt integer;
begin
    select count(distinct batch_no)::integer
    into l_cnt
    from deltaplan_keys
    where target_table = deltaplan.get_target_table()
      and data_segment = deltaplan.get_data_segment()
      and batch_no is not null;
    return l_cnt;
end;
$$;

create or replace procedure deltaplan.initialize(
    p_target_table    text,
    p_data_segment    text default 'all',
    p_lookback_hours  numeric default 0
)
language plpgsql
set search_path = pg_temp, public as $$
declare
    l_target  text := lower(p_target_table);
    l_segment text := lower(p_data_segment);
    l_lookback    numeric := coalesce(p_lookback_hours, 0);
    l_rows    bigint;
begin
    if p_target_table is null then
        raise exception 'DP-20006 target_table is required';
    end if;
    if p_data_segment is null then
        raise exception 'DP-20006 data_segment is required';
    end if;
    if l_lookback < 0 then
        raise exception 'DP-20002 lookback_hours must be >= 0';
    end if;

    call deltaplan._ensure_temp();

    insert into deltaplan_session (
        id, target_table, data_segment, lookback_hours,
        batch_no, batch_size, batch_commit, batches_ready, keys_durable, apply_open
    ) values (
        1, l_target, l_segment, l_lookback,
        null, null, true, false, false, false
    )
    on conflict (id) do update set
        target_table = excluded.target_table,
        data_segment = excluded.data_segment,
        lookback_hours = excluded.lookback_hours,
        batch_no = null,
        batch_size = null,
        batch_commit = true,
        batches_ready = false,
        keys_durable = false,
        apply_open = false;

    delete from deltaplan_keys
    where target_table = l_target
      and data_segment = l_segment;
    get diagnostics l_rows = row_count;

    delete from deltaplan_batch;

    raise notice 'deltaplan.initialize: % | target=% segment=% lookback_hours=%',
        l_rows, l_target, l_segment, l_lookback;
end;
$$;

-- p_lookback_hours null takes the value given to initialize.
-- p_sql must contain :since exactly once.
-- The placeholder is already the watermark minus the lookback offset.
create or replace procedure deltaplan.capture_delta(
    p_source_table    text,
    p_sql             text,
    p_lookback_hours  numeric default null
)
language plpgsql
set search_path = pg_temp, public as $$
declare
    l_source   text := lower(p_source_table);
    l_target   text;
    l_segment  text;
    l_lookback     numeric;
    l_stored   timestamp;
    l_bound    timestamp;
    l_ready    boolean;
    l_open     boolean;
    l_count    integer;
    l_sql      text;
    l_rows     bigint;
begin
    if to_regclass('deltaplan_session') is null then
        raise exception 'DP-20001 Call initialize first';
    end if;

    select target_table, data_segment, lookback_hours, batches_ready, apply_open
    into l_target, l_segment, l_lookback, l_ready, l_open
    from deltaplan_session
    where id = 1;

    if l_target is null then
        raise exception 'DP-20001 Call initialize first';
    end if;
    if l_source is null then
        raise exception 'DP-20006 source_table is required';
    end if;
    if p_sql is null or length(p_sql) = 0 then
        raise exception 'DP-20006 capture sql is required';
    end if;

    -- PostgreSQL regular expressions have no lookahead. \M is the end of a word,
    -- so :since2 does not count and :since does.
    select count(*)
    into l_count
    from regexp_matches(lower(p_sql), ':since\M', 'g');

    if l_count <> 1 then
        raise exception 'DP-20015 capture SQL must contain :since exactly once';
    end if;

    l_lookback := coalesce(p_lookback_hours, l_lookback, 0);
    if l_lookback < 0 then
        raise exception 'DP-20002 lookback_hours must be >= 0';
    end if;

    if l_ready or l_open or deltaplan._unfinished() > 0 then
        raise exception 'DP-20013 capture_delta is closed after prepare_batches until finalize';
    end if;

    select max(watermark)
    into l_stored
    from deltaplan_watermark
    where target_table = l_target
      and source_table = l_source
      and data_segment = l_segment;

    l_stored := coalesce(l_stored, timestamp '2000-01-01');
    l_bound := l_stored - (l_lookback * interval '1 hour');

    l_sql := regexp_replace(p_sql, ':since\M', '$1', 'gi');

    execute
        'insert into deltaplan_keys (
            target_table, data_segment, source_table,
            pk_1, pk_2, pk_3, watermark
        )
        select $2, $3, $4, s.pk_1, s.pk_2, s.pk_3, s.watermark
        from (' || l_sql || ') s'
        using l_bound, l_target, l_segment, l_source;

    get diagnostics l_rows = row_count;
    raise notice 'deltaplan.capture_delta: % | source=% stored=% bound=%',
        l_rows, l_source, l_stored, l_bound;
end;
$$;

-- Batches are optional. Without them the target statement reads deltaplan_keys.
-- With them: prepare_batches, then next_batch / SQL on deltaplan_batch / finish_batch.
-- p_commit true commits the captured keys first, then each finish_batch.
create or replace procedure deltaplan.prepare_batches(
    p_batch_size  numeric default 5000,
    p_commit      boolean default true
)
language plpgsql as $$
declare
    l_target    text;
    l_segment   text;
    l_size      numeric;
    l_commit    boolean;
    l_assigned  boolean;
    l_keys      bigint;
    l_updated   bigint;
    l_open_rows boolean;
    l_batch_no  numeric;
begin
    -- A SET clause on the procedure would forbid the commit below.
    set search_path = pg_temp, public;
    select target_table, data_segment, batch_size, batch_commit, batch_no
    into l_target, l_segment, l_size, l_commit, l_batch_no
    from deltaplan_session
    where id = 1;

    if l_target is null then
        raise exception 'DP-20001 Call initialize first';
    end if;
    if p_batch_size is null or p_batch_size < 1 or p_batch_size <> trunc(p_batch_size) then
        raise exception 'DP-20003 batch_size must be a positive integer';
    end if;

    select exists (
        select 1
        from deltaplan_keys
        where target_table = l_target
          and data_segment = l_segment
          and batch_no is not null
    ) into l_assigned;

    if l_assigned and l_size is not null and p_batch_size <> l_size then
        raise exception 'DP-20009 batch_size cannot change while batches are in progress, current=%', l_size;
    end if;
    if l_assigned and l_size is not null and p_commit is distinct from l_commit then
        raise exception 'DP-20018 p_commit cannot change while batches are in progress';
    end if;

    if l_batch_no is not null then
        select exists (select 1 from deltaplan_batch) into l_open_rows;
        if l_open_rows then
            raise exception 'DP-20014 batch % is open; call finish_batch', l_batch_no;
        end if;
    end if;

    select count(*)
    into l_keys
    from (
        select distinct pk_1, pk_2, pk_3
        from deltaplan_keys
        where target_table = l_target
          and data_segment = l_segment
    ) k;

    update deltaplan_session
    set batch_commit = p_commit,
        batches_ready = true,
        batch_no = null,
        batch_size = case when l_keys = 0 then batch_size else p_batch_size end,
        apply_open = false
    where id = 1;

    if l_keys = 0 then
        raise notice 'deltaplan.prepare_batches: 0 | no keys, nothing to apply';
        return;
    end if;

    if p_commit then
        update deltaplan_session
        set keys_durable = true
        where id = 1;
        commit;
        raise notice 'deltaplan.prepare_batches: % | committed captured keys before batches', l_keys;
    end if;

    if not l_assigned then
        update deltaplan_keys t
        set batch_no = s.batch_no,
            batch_done = 0
        from (
            select pk_1, pk_2, pk_3,
                   ceil(row_number() over (
                       order by pk_1, pk_2 nulls first, pk_3 nulls first
                   )::numeric / p_batch_size) as batch_no
            from (
                select distinct pk_1, pk_2, pk_3
                from deltaplan_keys
                where target_table = l_target
                  and data_segment = l_segment
            ) d
        ) s
        where t.target_table = l_target
          and t.data_segment = l_segment
          and t.pk_1 = s.pk_1
          and t.pk_2 is not distinct from s.pk_2
          and t.pk_3 is not distinct from s.pk_3
          and t.batch_no is null;

        get diagnostics l_updated = row_count;
        if l_updated = 0 then
            raise exception 'DP-20011 batch numbers were not assigned';
        end if;

        raise notice 'deltaplan.prepare_batches: % | assigned batch_no batch_size=% distinct_pk=%',
            l_updated, p_batch_size, l_keys;

        if p_commit then
            commit;
        end if;
    else
        raise notice 'deltaplan.prepare_batches: % | resume batch_size=%', l_keys, l_size;
    end if;

    if deltaplan._unfinished() = 0 then
        update deltaplan_session set apply_open = false where id = 1;
        raise notice 'deltaplan.prepare_batches: 0 | nothing left to apply';
        if p_commit then
            commit;
        end if;
        return;
    end if;

    update deltaplan_session set apply_open = true where id = 1;
    if p_commit then
        commit;
    end if;
end;
$$;

-- Returns true when a batch is open and its keys are in deltaplan_batch.
-- Returns false when no unfinished batch remains.
-- After rollback both this flag and deltaplan_batch return to the last commit,
-- and the next call loads the unfinished batch again.
create or replace function deltaplan.next_batch()
returns boolean
language plpgsql
set search_path = pg_temp, public as $$
declare
    l_target   text;
    l_segment  text;
    l_ready    boolean;
    l_open     boolean;
    l_batch_no numeric;
    l_keys     bigint;
    l_next     numeric;
begin
    select target_table, data_segment, batches_ready, apply_open, batch_no
    into l_target, l_segment, l_ready, l_open, l_batch_no
    from deltaplan_session
    where id = 1;

    if l_target is null then
        raise exception 'DP-20001 Call initialize first';
    end if;
    if not l_ready then
        raise exception 'DP-20016 Call prepare_batches first';
    end if;

    if l_batch_no is not null and exists (select 1 from deltaplan_batch) then
        raise exception 'DP-20014 batch % is open; call finish_batch', l_batch_no;
    end if;

    if not l_open and l_batch_no is null then
        return false;
    end if;

    if l_batch_no is not null then
        delete from deltaplan_batch;
        insert into deltaplan_batch (pk_1, pk_2, pk_3)
        select distinct pk_1, pk_2, pk_3
        from deltaplan_keys
        where target_table = l_target
          and data_segment = l_segment
          and batch_no = l_batch_no
          and batch_done = 0;
        get diagnostics l_keys = row_count;

        if l_keys > 0 then
            raise notice 'deltaplan.next_batch: % | batch %/% reopened',
                l_keys, l_batch_no, deltaplan._batch_total();
            return true;
        end if;

        update deltaplan_session set batch_no = null where id = 1;
    end if;

    select min(batch_no)
    into l_next
    from deltaplan_keys
    where target_table = l_target
      and data_segment = l_segment
      and batch_no is not null
      and batch_done = 0;

    if l_next is null then
        if deltaplan._unassigned() > 0 then
            raise exception 'DP-20011 batch numbers are missing; call prepare_batches';
        end if;

        update deltaplan_session
        set batch_no = null,
            apply_open = false
        where id = 1;
        delete from deltaplan_batch;
        raise notice 'deltaplan.next_batch: 0 | nothing left to apply';
        return false;
    end if;

    delete from deltaplan_batch;
    insert into deltaplan_batch (pk_1, pk_2, pk_3)
    select distinct pk_1, pk_2, pk_3
    from deltaplan_keys
    where target_table = l_target
      and data_segment = l_segment
      and batch_no = l_next
      and batch_done = 0;
    get diagnostics l_keys = row_count;

    if l_keys = 0 then
        raise exception 'DP-20011 batch % has no keys', l_next;
    end if;

    update deltaplan_session set batch_no = l_next where id = 1;
    raise notice 'deltaplan.next_batch: % | batch %/% opened',
        l_keys, l_next, deltaplan._batch_total();
    return true;
end;
$$;

-- Marks the open batch complete.
-- Commits when prepare_batches was called with p_commit true.
-- p_merged is recorded in the notice. PostgreSQL does not keep the
-- caller's row count, so pass it when the log should name the merge.
create or replace procedure deltaplan.finish_batch(p_merged bigint default null)
language plpgsql as $$
declare
    l_target   text;
    l_segment  text;
    l_batch_no numeric;
    l_commit   boolean;
    l_marked   bigint;
    l_left     integer;
begin
    set search_path = pg_temp, public;
    select target_table, data_segment, batch_no, batch_commit
    into l_target, l_segment, l_batch_no, l_commit
    from deltaplan_session
    where id = 1;

    if l_target is null then
        raise exception 'DP-20001 Call initialize first';
    end if;
    if l_batch_no is null then
        raise exception 'DP-20017 No open batch; call next_batch';
    end if;

    update deltaplan_keys
    set batch_done = 1
    where target_table = l_target
      and data_segment = l_segment
      and batch_no = l_batch_no
      and batch_done = 0;
    get diagnostics l_marked = row_count;

    if l_marked = 0 then
        raise exception 'DP-20012 batch % was not marked done', l_batch_no;
    end if;

    if l_commit then
        commit;
    else
        delete from deltaplan_batch;
    end if;

    l_left := deltaplan._unfinished();
    update deltaplan_session
    set batch_no = null,
        apply_open = l_left > 0
    where id = 1;

    if l_commit then
        commit;
    end if;

    raise notice 'deltaplan.finish_batch: batch % marked=% merged=% %',
        l_batch_no,
        l_marked,
        coalesce(p_merged::text, 'n/a'),
        case when l_commit then 'committed' else 'uncommitted' end;
end;
$$;

create or replace procedure deltaplan.finalize()
language plpgsql
set search_path = pg_temp, public as $$
declare
    l_target     text;
    l_segment    text;
    l_ready      boolean;
    l_open       boolean;
    l_left       integer;
    l_unassigned integer;
    l_all_pk     bigint;
    l_sources    integer := 0;
    r            record;
    l_old        timestamp;
    l_effective  timestamp;
begin
    if to_regclass('deltaplan_session') is null then
        raise exception 'DP-20001 Call initialize first';
    end if;

    select target_table, data_segment, batches_ready, apply_open
    into l_target, l_segment, l_ready, l_open
    from deltaplan_session
    where id = 1;

    if l_target is null then
        raise exception 'DP-20001 Call initialize first';
    end if;

    l_left := deltaplan._unfinished();
    l_unassigned := deltaplan._unassigned();

    select count(*)
    into l_all_pk
    from (
        select distinct pk_1, pk_2, pk_3
        from deltaplan_keys
        where target_table = l_target
          and data_segment = l_segment
    ) k;

    if l_left > 0
       or (l_open and l_all_pk > 0)
       or (l_ready and l_unassigned > 0) then
        raise exception
            'DP-20005 unfinished batches for % (% left). Watermark was not moved. Call prepare_batches, then next_batch and finish_batch, to resume.',
            l_target, l_left;
    end if;

    for r in
        select s.source_table, s.watermark
        from (
            select source_table, max(watermark) as watermark
            from deltaplan_keys
            where target_table = l_target
              and data_segment = l_segment
            group by source_table
        ) s
        order by s.source_table
    loop
        select watermark
        into l_old
        from deltaplan_watermark
        where target_table = l_target
          and data_segment = l_segment
          and source_table = r.source_table;

        if not found or r.watermark > l_old then
            l_effective := r.watermark;
        else
            l_effective := l_old;
        end if;

        insert into deltaplan_watermark (target_table, data_segment, source_table, watermark, updated_at)
        values (l_target, l_segment, r.source_table, l_effective, clock_timestamp()::timestamp)
        on conflict (target_table, data_segment, source_table) do update
            set watermark = excluded.watermark,
                updated_at = excluded.updated_at
            where deltaplan_watermark.watermark < excluded.watermark;

        l_sources := l_sources + 1;
        raise notice 'deltaplan.finalize: source=% stored=% captured=% effective=%',
            r.source_table, l_old, r.watermark, l_effective;
    end loop;

    if l_sources = 0 then
        raise notice 'deltaplan.finalize: no delta, watermarks unchanged';
    end if;

    delete from deltaplan_batch;
    update deltaplan_session
    set target_table = null,
        data_segment = null,
        lookback_hours = 0,
        batch_no = null,
        batch_size = null,
        batch_commit = true,
        batches_ready = false,
        keys_durable = false,
        apply_open = false
    where id = 1;
end;
$$;
