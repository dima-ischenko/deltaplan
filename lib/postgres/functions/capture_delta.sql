-- p_lookback_hours null takes the value given to initialize.
-- p_sql must contain :since exactly once.
-- The placeholder is already the watermark minus the lookback offset.
-- The statement must return pk_1 and watermark. pk_2 and pk_3 are optional.
-- p_owner defaults to the current schema. The source must exist and be selectable.
create or replace function capture_delta(
    p_source_table    text,
    p_sql             text,
    p_lookback_hours  numeric default null,
    p_owner           text default null
)
returns void
language plpgsql
set search_path = pg_temp, :"dwv_schema", public as $$
declare
l_source_owner text;
l_source   text;
l_target_owner text;
l_target   text;
l_slice    text;
l_lookback     numeric;
l_stored   timestamp;
l_bound    timestamp;
l_ready    boolean;
l_count    integer;
l_sql      text;
l_pk2      text;
l_pk3      text;
l_rows     bigint;
l_slice_rows bigint;
l_slice_pk   bigint;
l_min        timestamp;
l_max        timestamp;
begin
  if to_regclass('dwv_session_tmp') is null then
    raise exception 'DWV-20001 Call initialize first';
  end if;

  select target_owner, target_table, data_slice, lookback_hours, batches_ready
  into l_target_owner, l_target, l_slice, l_lookback, l_ready
  from dwv_session_tmp
  where id = 1;

  if l_target is null then
    raise exception 'DWV-20001 Call initialize first';
  end if;

  select q.o_owner, q.o_table
  into l_source_owner, l_source
  from _qualify_relation(p_owner, p_source_table, 'source_table') q;

  if p_sql is null or length(p_sql) = 0 then
    raise exception 'DWV-20006 capture sql is required';
  end if;

  -- \M is the end of a word, so :since2 does not count.
  select count(*)
  into l_count
  from regexp_matches(lower(p_sql), ':since\M', 'g');

  if l_count <> 1 then
    raise exception 'DWV-20015 capture SQL must contain :since exactly once';
  end if;

  l_lookback := coalesce(p_lookback_hours, l_lookback, 0);
  if l_lookback < 0 then
    raise exception 'DWV-20002 lookback_hours must be >= 0';
  end if;

  if l_ready then
    raise exception 'DWV-20013 capture_delta is closed after prepare_batches until finalize';
  end if;

  if _unfinished() > 0 then
    raise exception 'DWV-20013 capture_delta is closed after prepare_batches until finalize';
  end if;

  select max(watermark)
  into l_stored
  from dwv_watermark
  where target_owner = l_target_owner
   and target_table = l_target
   and source_owner = l_source_owner
   and source_table = l_source
   and data_slice = l_slice;

  l_stored := coalesce(l_stored, timestamp '2000-01-01');
  l_bound := l_stored - (l_lookback * interval '1 hour');

  l_sql := regexp_replace(p_sql, ':since\M', '$1', 'gi');

  begin
    execute 'select s.pk_1 from (' || l_sql || ') s where false' using l_bound;
  exception
    when undefined_column then
      if position('pk_1' in lower(sqlerrm)) > 0 then
        raise exception 'DWV-20020 capture SQL must return pk_1 and watermark; pk_2 and pk_3 are optional';
      end if;
      raise;
end;

  begin
    execute 'select s.watermark from (' || l_sql || ') s where false' using l_bound;
  exception
    when undefined_column then
      if position('watermark' in lower(sqlerrm)) > 0 then
        raise exception 'DWV-20020 capture SQL must return pk_1 and watermark; pk_2 and pk_3 are optional';
      end if;
      raise;
end;

  l_pk2 := 'null::text';
  begin
    execute 'select s.pk_2 from (' || l_sql || ') s where false' using l_bound;
    l_pk2 := 's.pk_2';
  exception
    when undefined_column then
      if position('pk_2' in lower(sqlerrm)) = 0 then
        raise;
      end if;
end;

  l_pk3 := 'null::text';
  begin
    execute 'select s.pk_3 from (' || l_sql || ') s where false' using l_bound;
    l_pk3 := 's.pk_3';
  exception
    when undefined_column then
      if position('pk_3' in lower(sqlerrm)) = 0 then
        raise;
      end if;
end;

  execute
    'insert into dwv_keys_tmp (
      source_owner, source_table, pk_1, pk_2, pk_3, watermark
    )
    select $2, $3, s.pk_1, ' || l_pk2 || ', ' || l_pk3 || ', s.watermark
    from (' || l_sql || ') s'
    using l_bound, l_source_owner, l_source;

  get diagnostics l_rows = row_count;

  if _debug() then
    select coalesce(sum(cnt), 0),
       min(min_wm),
       max(max_wm),
       count(*)
    into l_slice_rows, l_min, l_max, l_slice_pk
    from (
      select count(*) cnt,
         min(watermark) min_wm,
         max(watermark) max_wm
      from dwv_keys_tmp
      where source_owner = l_source_owner
        and source_table = l_source
      group by pk_1, pk_2, pk_3
    ) s;
    perform _log(
      'capture_delta',
      l_rows,
      format(
        'source=%s.%s stored=%s bound=%s inserted=%s slice_rows=%s slice_pk=%s min=%s max=%s',
        l_source_owner, l_source, l_stored, l_bound, l_rows,
        l_slice_rows, l_slice_pk, l_min, l_max
      )
    );
  else
    perform _log(
      'capture_delta',
      l_rows,
      format('source=%s.%s stored=%s bound=%s', l_source_owner, l_source, l_stored, l_bound)
    );
  end if;
end;
$$;
