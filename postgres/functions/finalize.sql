create or replace function deltaplan.finalize()
returns void
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
    if to_regclass('deltaplan_session_tmp') is null then
        raise exception 'DP-20001 Call initialize first';
    end if;

    select target_table, data_segment, batches_ready, apply_open
    into l_target, l_segment, l_ready, l_open
    from deltaplan_session_tmp
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
        from deltaplan_keys_tmp
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
            from deltaplan_keys_tmp
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

    delete from deltaplan_batch_tmp;
    update deltaplan_session_tmp
    set target_table = null,
        data_segment = null,
        lookback_hours = 0,
        batch_no = null,
        batch_size = null,
        batches_ready = false,
        apply_open = false
    where id = 1;
end;
$$;
