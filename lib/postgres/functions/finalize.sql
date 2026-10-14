create or replace function finalize()
returns void
language plpgsql
set search_path = pg_temp, :"dpl_schema", public as $$
declare
    l_target     text;
    l_segment    text;
    l_ready      boolean;
    l_left       integer := 0;
    l_unassigned integer := 0;
    l_moved      integer := 0;
    l_all_pk     integer := 0;
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

    if l_ready then
        l_left := _unfinished();
        l_unassigned := _unassigned();
    end if;

    if l_left > 0
       or l_unassigned > 0 then
        raise exception
            'DP-20005 unfinished batches for % (% left). Watermark was not moved. Finish the remaining batches before calling finalize.',
            l_target, l_left;
    end if;

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

    if _debug() then
        select count(*)::integer
        into l_all_pk
        from (
            select distinct pk_1, pk_2, pk_3
            from dpl_keys_tmp
        ) k;
        perform _log(
            'finalize',
            l_moved,
            format('moved=%s distinct_pk=%s', l_moved, l_all_pk)
        );
    else
        perform _log('finalize', l_moved, format('moved=%s', l_moved));
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
