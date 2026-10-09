-- Batches are optional. Without them the refresh statement reads deltaplan_keys_tmp.
-- With them: prepare_batches, then next_batch / SQL on deltaplan_batch_tmp / finish_batch.
-- This function does not commit. Commit after prepare_batches if a later
-- rollback should keep the captured keys, and after each finish_batch if
-- a later rollback should keep that batch. next_batch, the refresh statement
-- and finish_batch stay in one transaction: deltaplan_batch_tmp is
-- ON COMMIT DELETE ROWS.
create or replace function deltaplan.prepare_batches(
    p_batch_size  numeric default 5000
)
returns void
language plpgsql
set search_path = pg_temp, public as $$
declare
    l_target    text;
    l_segment   text;
    l_size      numeric;
    l_assigned  boolean;
    l_keys      bigint;
    l_updated   bigint;
    l_open_rows boolean;
    l_batch_no  numeric;
begin
    select target_table, data_segment, batch_size, batch_no
    into l_target, l_segment, l_size, l_batch_no
    from deltaplan_session_tmp
    where id = 1;

    if l_target is null then
        raise exception 'DP-20001 Call initialize first';
    end if;
    if p_batch_size is null or p_batch_size < 1 or p_batch_size <> trunc(p_batch_size) then
        raise exception 'DP-20003 batch_size must be a positive integer';
    end if;

    select exists (
        select 1
        from deltaplan_keys_tmp
        where target_table = l_target
          and data_segment = l_segment
          and batch_no is not null
    ) into l_assigned;

    if l_assigned and l_size is not null and p_batch_size <> l_size then
        raise exception 'DP-20009 batch_size cannot change while batches are in progress, current=%', l_size;
    end if;

    if l_batch_no is not null then
        select exists (select 1 from deltaplan_batch_tmp) into l_open_rows;
        if l_open_rows then
            raise exception 'DP-20014 batch % is open; call finish_batch', l_batch_no;
        end if;
    end if;

    select count(*)
    into l_keys
    from (
        select distinct pk_1, pk_2, pk_3
        from deltaplan_keys_tmp
        where target_table = l_target
          and data_segment = l_segment
    ) k;

    update deltaplan_session_tmp
    set batches_ready = true,
        batch_no = null,
        batch_size = case when l_keys = 0 then batch_size else p_batch_size end,
        apply_open = false
    where id = 1;

    if l_keys = 0 then
        raise notice 'deltaplan.prepare_batches: 0 | no keys, nothing to apply';
        return;
    end if;

    if not l_assigned then
        update deltaplan_keys_tmp t
        set batch_no = s.batch_no,
            batch_done = 0
        from (
            select pk_1, pk_2, pk_3,
                   ceil(row_number() over (
                       order by pk_1, pk_2 nulls first, pk_3 nulls first
                   )::numeric / p_batch_size) as batch_no
            from (
                select distinct pk_1, pk_2, pk_3
                from deltaplan_keys_tmp
                where target_table = l_target
                  and data_segment = l_segment
            ) d
        ) s
        where t.target_table = l_target
          and t.data_segment = l_segment
          and t.pk_1 = s.pk_1
          and t.pk_2 is not distinct from s.pk_2
          and t.pk_3 is not distinct from s.pk_3
          and t.batch_no is null;

        get diagnostics l_updated = row_count;
        if l_updated = 0 then
            raise exception 'DP-20011 batch numbers were not assigned';
        end if;

        raise notice 'deltaplan.prepare_batches: % | assigned batch_no batch_size=% distinct_pk=%',
            l_updated, p_batch_size, l_keys;
    else
        raise notice 'deltaplan.prepare_batches: % | resume batch_size=%', l_keys, l_size;
    end if;

    if deltaplan._unfinished() = 0 then
        update deltaplan_session_tmp set apply_open = false where id = 1;
        raise notice 'deltaplan.prepare_batches: 0 | nothing left to apply';
        return;
    end if;

    update deltaplan_session_tmp set apply_open = true where id = 1;
end;
$$;
