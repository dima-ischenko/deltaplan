create or replace function _batch_total()
returns integer
language plpgsql stable
set search_path = pg_temp, :"dpl_schema", public as $$
declare
l_cnt integer;
begin
  select count(distinct batch_no)::integer
  into l_cnt
  from dpl_keys_tmp
  where batch_no is not null;
  return l_cnt;
end;
$$;
