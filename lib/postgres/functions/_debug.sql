create or replace function _debug()
returns boolean
language plpgsql stable
set search_path = pg_temp, :"dwa_schema", public as $$
begin
  if to_regclass('dwa_session_tmp') is null then
    return false;
  end if;
  return coalesce((select debug from dwa_session_tmp where id = 1), false);
end;
$$;
