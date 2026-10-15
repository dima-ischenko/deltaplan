create or replace function set_log_table(p_enabled boolean default true)
returns void
language plpgsql
set search_path = pg_temp, :"dwv_schema", public as $$
begin
  perform _ensure_temp();
  insert into dwv_session_tmp (id, log_table)
  values (1, p_enabled is true)
  on conflict (id) do update set log_table = excluded.log_table;
end;
$$;
