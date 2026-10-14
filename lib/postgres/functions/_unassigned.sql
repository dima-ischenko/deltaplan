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
    where batch_no is null;
    return l_cnt;
end;
$$;
