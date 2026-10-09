-- Marks the open batch complete. Does not commit.
-- p_merged is recorded in the notice. PostgreSQL does not keep the
-- caller's row count, so pass it when the log should name the merge.
create or replace function deltaplan.finish_batch(p_merged bigint default null)
returns void
language plpgsql
set search_path = pg_temp, public as $$
declare
    l_target   text;
    l_segment  text;
    l_batch_no numeric;
    l_marked   bigint;
    l_left     integer;
begin
    select target_table, data_segment, batch_no
    into l_target, l_segment, l_batch_no
    from deltaplan_session_tmp
    where id = 1;

    if l_target is null then
        raise exception 'DP-20001 Call initialize first';
    end if;
    if l_batch_no is null then
        raise exception 'DP-20017 No open batch; call next_batch';
    end if;

    update deltaplan_keys_tmp
    set batch_done = 1
    where target_table = l_target
      and data_segment = l_segment
      and batch_no = l_batch_no
      and batch_done = 0;
    get diagnostics l_marked = row_count;

    if l_marked = 0 then
        raise exception 'DP-20012 batch % was not marked done', l_batch_no;
    end if;

    delete from deltaplan_batch_tmp;

    l_left := deltaplan._unfinished();
    update deltaplan_session_tmp
    set batch_no = null,
        apply_open = l_left > 0
    where id = 1;

    raise notice 'deltaplan.finish_batch: batch % marked=% merged=%',
        l_batch_no,
        l_marked,
        coalesce(p_merged::text, 'n/a');
end;
$$;
