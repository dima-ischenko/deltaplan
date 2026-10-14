-- Marks the open batch complete. Does not commit.
-- Pass p_merged when the log should show the refresh row count.
create or replace function finish_batch(p_merged bigint default null)
returns void
language plpgsql
set search_path = pg_temp, :"dpl_schema", public as $$
declare
l_target   text;
l_batch_no numeric;
l_marked   bigint;
begin
  select target_table, batch_no
  into l_target, l_batch_no
  from dpl_session_tmp
  where id = 1;

  if l_target is null then
    raise exception 'DP-20001 Call initialize first';
  end if;
  if l_batch_no is null then
    raise exception 'DP-20017 No open batch; call next_batch';
  end if;

  update dpl_keys_tmp
  set batch_done = 1
  where batch_no = l_batch_no
   and batch_done = 0;
  get diagnostics l_marked = row_count;

  if l_marked = 0 then
    raise exception 'DP-20012 batch % was not marked done', l_batch_no;
  end if;

  delete from dpl_batch_tmp;

  update dpl_session_tmp
  set batch_no = null
  where id = 1;

  perform _log(
    'finish_batch',
    coalesce(p_merged, l_marked),
    format(
      'batch %s marked=%s merged=%s',
      l_batch_no,
      l_marked,
      coalesce(p_merged::text, 'n/a')
    )
  );
end;
$$;
