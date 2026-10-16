create or replace function get_target_table()
returns text
language plpgsql stable
set search_path = pg_temp, :"dwa_schema", public as $$
begin
  if to_regclass('dwa_session_tmp') is null then
    return null;
  end if;
  return (select target_table from dwa_session_tmp where id = 1);
end;
$$;
