create or replace function _unassigned()
returns integer
language plpgsql stable
set search_path = pg_temp, :"dpl_schema", public as $$
declare
    l_cnt integer;
begin
    select count(*)::integer
    into l_cnt
    from dpl_keys_tmp
    where target_table = get_target_table()
      and data_segment = get_data_segment()
      and batch_no is null;
    return l_cnt;
end;
$$;
