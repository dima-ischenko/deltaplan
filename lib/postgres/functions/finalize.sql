create or replace function finalize()
returns void
language plpgsql
set search_path = pg_temp, :"dwa_schema", public as $$
declare
l_owner      text;
l_target     text;
l_slice      text;
l_ready      boolean;
l_left       integer := 0;
l_unassigned integer := 0;
l_moved      integer := 0;
l_all_pk     integer := 0;
begin
  if to_regclass('dwa_session_tmp') is null then
    raise exception 'DWA-20001 Call initialize first';
  end if;

  select target_owner, target_table, data_slice, batches_ready
  into l_owner, l_target, l_slice, l_ready
  from dwa_session_tmp
  where id = 1;

  if l_target is null then
    raise exception 'DWA-20001 Call initialize first';
  end if;

  if l_ready then
    l_left := _unfinished();
    l_unassigned := _unassigned();
  end if;

  if l_left > 0
   or l_unassigned > 0 then
    raise exception
      'DWA-20005 unfinished batches for %.% (% left). Watermark was not moved. Finish the remaining batches before calling finalize.',
      l_owner, l_target, l_left;
  end if;

  insert into dwa_watermark (
    target_owner, target_table, data_slice,
    source_owner, source_table, watermark, updated_at
  )
  select l_owner,
     l_target,
     l_slice,
     source_owner,
     source_table,
     max(watermark),
     clock_timestamp()::timestamp
  from dwa_keys_tmp
  group by source_owner, source_table
  on conflict (target_owner, target_table, data_slice, source_owner, source_table) do update
    set watermark = excluded.watermark,
      updated_at = excluded.updated_at
    where dwa_watermark.watermark < excluded.watermark;

  get diagnostics l_moved = row_count;

  if _debug() then
    select count(*)::integer
    into l_all_pk
    from (
      select distinct pk_1, pk_2, pk_3
      from dwa_keys_tmp
    ) k;
    perform _log(
      'finalize',
      l_moved,
      format('moved=%s distinct_pk=%s', l_moved, l_all_pk)
    );
  else
    perform _log('finalize', l_moved, format('moved=%s', l_moved));
  end if;

  delete from dwa_batch_tmp;
  perform _release_run_lock(l_owner, l_target, l_slice);

  update dwa_session_tmp
  set target_owner = null,
    target_table = null,
    data_slice = null,
    lookback_hours = 0,
    batch_no = null,
    batch_size = null,
    batches_ready = false
  where id = 1;
end;
$$;
