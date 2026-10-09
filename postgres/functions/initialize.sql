create or replace function deltaplan.initialize(
    p_target_table    text,
    p_data_segment    text default 'all',
    p_lookback_hours  numeric default 0
)
returns void
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

    perform deltaplan._ensure_temp();

    insert into deltaplan_session_tmp (
        id, target_table, data_segment, lookback_hours,
        batch_no, batch_size, batches_ready, apply_open
    ) values (
        1, l_target, l_segment, l_lookback,
        null, null, false, false
    )
    on conflict (id) do update set
        target_table = excluded.target_table,
        data_segment = excluded.data_segment,
        lookback_hours = excluded.lookback_hours,
        batch_no = null,
        batch_size = null,
        batches_ready = false,
        apply_open = false;

    delete from deltaplan_keys_tmp
    where target_table = l_target
      and data_segment = l_segment;
    get diagnostics l_rows = row_count;

    delete from deltaplan_batch_tmp;

    raise notice 'deltaplan.initialize: % | target=% segment=% lookback_hours=%',
        l_rows, l_target, l_segment, l_lookback;
end;
$$;
