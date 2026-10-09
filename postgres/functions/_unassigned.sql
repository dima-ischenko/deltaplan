create or replace function deltaplan._unassigned()
returns integer
language plpgsql stable
set search_path = pg_temp, public as $$
declare
    l_cnt integer;
begin
    select count(*)::integer
    into l_cnt
    from deltaplan_keys_tmp
    where target_table = deltaplan.get_target_table()
      and data_segment = deltaplan.get_data_segment()
      and batch_no is null;
    return l_cnt;
end;
$$;
