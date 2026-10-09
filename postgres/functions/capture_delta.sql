-- p_lookback_hours null takes the value given to initialize.
-- p_sql must contain :since exactly once.
-- The placeholder is already the watermark minus the lookback offset.
create or replace function capture_delta(
    p_source_table    text,
    p_sql             text,
    p_lookback_hours  numeric default null
)
returns void
language plpgsql
set search_path = pg_temp, :"dpl_schema", public as $$
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
    if to_regclass('dpl_session_tmp') is null then
        raise exception 'DP-20001 Call initialize first';
    end if;

    select target_table, data_segment, lookback_hours, batches_ready, apply_open
    into l_target, l_segment, l_lookback, l_ready, l_open
    from dpl_session_tmp
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

    if l_ready or l_open or _unfinished() > 0 then
        raise exception 'DP-20013 capture_delta is closed after prepare_batches until finalize';
    end if;

    select max(watermark)
    into l_stored
    from dpl_watermark
    where target_table = l_target
      and source_table = l_source
      and data_segment = l_segment;

    l_stored := coalesce(l_stored, timestamp '2000-01-01');
    l_bound := l_stored - (l_lookback * interval '1 hour');

    l_sql := regexp_replace(p_sql, ':since\M', '$1', 'gi');

    execute
        'insert into dpl_keys_tmp (
            target_table, data_segment, source_table,
            pk_1, pk_2, pk_3, watermark
        )
        select $2, $3, $4, s.pk_1, s.pk_2, s.pk_3, s.watermark
        from (' || l_sql || ') s'
        using l_bound, l_target, l_segment, l_source;

    get diagnostics l_rows = row_count;
    raise notice 'capture_delta: % | source=% stored=% bound=%',
        l_rows, l_source, l_stored, l_bound;
end;
$$;
