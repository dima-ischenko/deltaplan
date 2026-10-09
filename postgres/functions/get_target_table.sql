create or replace function get_target_table()
returns text
language plpgsql stable
set search_path = pg_temp, :"dpl_schema", public as $$
begin
    if to_regclass('dpl_session_tmp') is null then
        return null;
    end if;
    return (select target_table from dpl_session_tmp where id = 1);
end;
$$;
