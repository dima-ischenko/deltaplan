-- Exclusive session lock on (owner, target, slice). Another session gets DWA-20021.
-- p_owner omitted: resolve the unqualified name, then store that schema.
create or replace function initialize(
    p_target_table    text,
    p_data_slice      text default 'all',
    p_lookback_hours  numeric default 0,
    p_debug           boolean default false,
    p_owner           text default null
)
returns void
language plpgsql
set search_path = pg_temp, :"dwa_schema", public as $$
declare
l_owner   text;
l_target  text;
l_slice   text := _norm_ident(p_data_slice, 'data_slice');
l_lookback    numeric := coalesce(p_lookback_hours, 0);
l_rows    bigint;
begin
  if l_lookback < 0 then
    raise exception 'DWA-20002 lookback_hours must be >= 0';
  end if;

  select q.o_owner, q.o_table
  into l_owner, l_target
  from _qualify_relation(p_owner, p_target_table, 'target_table') q;

  perform _ensure_temp();

  insert into dwa_session_tmp (
    id, target_owner, target_table, data_slice, lookback_hours,
    batch_no, batch_size, batches_ready, debug
  ) values (
    1, l_owner, l_target, l_slice, l_lookback,
    null, null, false, p_debug is true
  )
  on conflict (id) do update set
    target_owner = excluded.target_owner,
    target_table = excluded.target_table,
    data_slice = excluded.data_slice,
    lookback_hours = excluded.lookback_hours,
    batch_no = null,
    batch_size = null,
    batches_ready = false,
    debug = excluded.debug;

  perform _acquire_run_lock(l_owner, l_target, l_slice);

  delete from dwa_keys_tmp;
  get diagnostics l_rows = row_count;

  delete from dwa_batch_tmp;

  perform _log(
    'initialize',
    l_rows,
    format(
      'target=%s.%s slice=%s lookback_hours=%s',
      l_owner, l_target, l_slice, l_lookback
    )
  );
end;
$$;
