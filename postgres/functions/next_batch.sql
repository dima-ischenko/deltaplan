-- Returns true when a batch is open and its keys are in dpl_batch_tmp.
-- Returns false when no unfinished batch remains.
-- After rollback both this flag and dpl_batch_tmp return to the last commit,
-- and the next call loads the unfinished batch again.
create or replace function next_batch()
returns boolean
language plpgsql
set search_path = pg_temp, :"dpl_schema", public as $$
declare
    l_target   text;
    l_segment  text;
    l_ready    boolean;
    l_open     boolean;
    l_batch_no numeric;
    l_keys     bigint;
    l_next     numeric;
begin
    select target_table, data_segment, batches_ready, apply_open, batch_no
    into l_target, l_segment, l_ready, l_open, l_batch_no
    from dpl_session_tmp
    where id = 1;

    if l_target is null then
        raise exception 'DP-20001 Call initialize first';
    end if;
    if not l_ready then
        raise exception 'DP-20016 Call prepare_batches first';
    end if;

    if l_batch_no is not null and exists (select 1 from dpl_batch_tmp) then
        raise exception 'DP-20014 batch % is open; call finish_batch', l_batch_no;
    end if;

    if not l_open and l_batch_no is null then
        return false;
    end if;

    if l_batch_no is not null then
        delete from dpl_batch_tmp;
        insert into dpl_batch_tmp (pk_1, pk_2, pk_3)
        select distinct pk_1, pk_2, pk_3
        from dpl_keys_tmp
        where target_table = l_target
          and data_segment = l_segment
          and batch_no = l_batch_no
          and batch_done = 0;
        get diagnostics l_keys = row_count;

        if l_keys > 0 then
            raise notice 'next_batch: % | batch %/% reopened',
                l_keys, l_batch_no, _batch_total();
            return true;
        end if;

        update dpl_session_tmp set batch_no = null where id = 1;
    end if;

    select min(batch_no)
    into l_next
    from dpl_keys_tmp
    where target_table = l_target
      and data_segment = l_segment
      and batch_no is not null
      and batch_done = 0;

    if l_next is null then
        if _unassigned() > 0 then
            raise exception 'DP-20011 batch numbers are missing; call prepare_batches';
        end if;

        update dpl_session_tmp
        set batch_no = null,
            apply_open = false
        where id = 1;
        delete from dpl_batch_tmp;
        raise notice 'next_batch: 0 | nothing left to apply';
        return false;
    end if;

    delete from dpl_batch_tmp;
    insert into dpl_batch_tmp (pk_1, pk_2, pk_3)
    select distinct pk_1, pk_2, pk_3
    from dpl_keys_tmp
    where target_table = l_target
      and data_segment = l_segment
      and batch_no = l_next
      and batch_done = 0;
    get diagnostics l_keys = row_count;

    if l_keys = 0 then
        raise exception 'DP-20011 batch % has no keys', l_next;
    end if;

    update dpl_session_tmp set batch_no = l_next where id = 1;
    raise notice 'next_batch: % | batch %/% opened',
        l_keys, l_next, _batch_total();
    return true;
end;
$$;
