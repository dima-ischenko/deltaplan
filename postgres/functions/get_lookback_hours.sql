create or replace function get_lookback_hours()
returns numeric
language plpgsql stable
set search_path = pg_temp, :"dpl_schema", public as $$
begin
    if to_regclass('dpl_session_tmp') is null then
        return null;
    end if;
    return (select lookback_hours from dpl_session_tmp where id = 1);
end;
$$;
