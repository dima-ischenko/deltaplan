-- These read the session's temporary tables, which do not exist until initialize.
create or replace function _unfinished()
returns integer
language plpgsql stable
set search_path = pg_temp, :"dpl_schema", public as $$
declare
    l_left integer;
begin
    select count(distinct batch_no)::integer
    into l_left
    from dpl_keys_tmp
    where target_table = get_target_table()
      and data_segment = get_data_segment()
      and batch_no is not null
      and batch_done = 0;
    return l_left;
end;
$$;
