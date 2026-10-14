create or replace function finalize()
returns void
language plpgsql
set search_path = pg_temp, :"dpl_schema", public as $$
declare
    l_target     text;
    l_segment    text;
    l_ready      boolean;
    l_left       integer;
    l_unassigned integer;
    l_sources    integer := 0;
    l_moved      integer := 0;
begin
    if to_regclass('dpl_session_tmp') is null then
        raise exception 'DP-20001 Call initialize first';
    end if;

    select target_table, data_segment, batches_ready
    into l_target, l_segment, l_ready
    from dpl_session_tmp
    where id = 1;

    if l_target is null then
        raise exception 'DP-20001 Call initialize first';
    end if;

    l_left := _unfinished();
    l_unassigned := _unassigned();

    if l_left > 0
       or (l_ready and l_unassigned > 0) then
        raise exception
            'DP-20005 unfinished batches for % (% left). Watermark was not moved. Finish the remaining batches before calling finalize.',
            l_target, l_left;
    end if;

    select count(*)
    into l_sources
    from (
        select source_table
        from dpl_keys_tmp
        group by source_table
    ) s;

    if l_sources = 0 then
        perform _log('finalize', 0, 'no delta, watermarks unchanged');
    else
        insert into dpl_watermark (
            target_table, data_segment, source_table, watermark, updated_at
        )
        select l_target,
               l_segment,
               source_table,
               max(watermark),
               clock_timestamp()::timestamp
        from dpl_keys_tmp
        group by source_table
        on conflict (target_table, data_segment, source_table) do update
            set watermark = excluded.watermark,
                updated_at = excluded.updated_at
            where dpl_watermark.watermark < excluded.watermark;

        get diagnostics l_moved = row_count;

        perform _log(
            'finalize',
            l_sources,
            format('sources=%s moved=%s', l_sources, l_moved)
        );
    end if;

    delete from dpl_batch_tmp;
    update dpl_session_tmp
    set target_table = null,
        data_segment = null,
        lookback_hours = 0,
        batch_no = null,
        batch_size = null,
        batches_ready = false
    where id = 1;
end;
$$;
