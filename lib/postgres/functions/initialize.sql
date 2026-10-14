create or replace function initialize(
    p_target_table    text,
    p_data_segment    text default 'all',
    p_lookback_hours  numeric default 0,
    p_debug           boolean default false
)
returns void
language plpgsql
set search_path = pg_temp, :"dpl_schema", public as $$
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

    perform _ensure_temp();

    insert into dpl_session_tmp (
        id, target_table, data_segment, lookback_hours,
        batch_no, batch_size, batches_ready, debug
    ) values (
        1, l_target, l_segment, l_lookback,
        null, null, false, p_debug is true
    )
    on conflict (id) do update set
        target_table = excluded.target_table,
        data_segment = excluded.data_segment,
        lookback_hours = excluded.lookback_hours,
        batch_no = null,
        batch_size = null,
        batches_ready = false,
        debug = excluded.debug;

    delete from dpl_keys_tmp;
    get diagnostics l_rows = row_count;

    delete from dpl_batch_tmp;

    perform _log(
        'initialize',
        l_rows,
        format('target=%s segment=%s lookback_hours=%s', l_target, l_segment, l_lookback)
    );
end;
$$;
