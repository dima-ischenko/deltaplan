-- Returns true when a batch is open and its keys are in dwv_batch_tmp.
-- Returns false when no unfinished batch remains.
-- next_batch, the refresh statement, and finish_batch stay in one transaction.
-- A commit empties dwv_batch_tmp. If that commit happens before finish_batch,
-- the open batch's keys are gone and the next call raises DWV-20019.
create or replace function next_batch()
returns boolean
language plpgsql
set search_path = pg_temp, :"dwv_schema", public as $$
declare
l_target   text;
l_ready    boolean;
l_batch_no numeric;
l_keys     bigint;
l_next     numeric;
begin
  select target_table, batches_ready, batch_no
  into l_target, l_ready, l_batch_no
  from dwv_session_tmp
  where id = 1;

  if l_target is null then
    raise exception 'DWV-20001 Call initialize first';
  end if;
  if not l_ready then
    raise exception 'DWV-20016 Call prepare_batches first';
  end if;

  if l_batch_no is not null and exists (select 1 from dwv_batch_tmp) then
    raise exception 'DWV-20014 batch % is open; call finish_batch', l_batch_no;
  end if;
  if l_batch_no is not null then
    raise exception 'DWV-20019 batch % lost its keys; call initialize', l_batch_no;
  end if;

  select min(batch_no)
  into l_next
  from dwv_keys_tmp
  where batch_no is not null
   and batch_done = 0;

  if l_next is null then
    if _unassigned() > 0 then
      raise exception 'DWV-20011 batch numbers are missing; call prepare_batches';
    end if;

    update dwv_session_tmp
    set batch_no = null
    where id = 1;
    delete from dwv_batch_tmp;
    perform _log('next_batch', 0, 'nothing left to apply');
    return false;
  end if;

  delete from dwv_batch_tmp;
  insert into dwv_batch_tmp (pk_1, pk_2, pk_3)
  select distinct pk_1, pk_2, pk_3
  from dwv_keys_tmp
  where batch_no = l_next
   and batch_done = 0;
  get diagnostics l_keys = row_count;

  if l_keys = 0 then
    raise exception 'DWV-20011 batch % has no keys', l_next;
  end if;

  update dwv_session_tmp set batch_no = l_next where id = 1;
  perform _log(
    'next_batch',
    l_keys,
    format('batch %s opened', l_next)
  );
  return true;
end;
$$;
