create or replace function _unassigned()
returns integer
language plpgsql stable
set search_path = pg_temp, :"dwa_schema", public as $$
begin
  if exists (
    select 1
    from dwa_keys_tmp
    where batch_no is null
  ) then
    return 1;
  end if;
  return 0;
end;
$$;
