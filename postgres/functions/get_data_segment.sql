create or replace function deltaplan.get_data_segment()
returns text
language plpgsql stable
set search_path = pg_temp, public as $$
begin
    if to_regclass('deltaplan_session_tmp') is null then
        return null;
    end if;
    return (select data_segment from deltaplan_session_tmp where id = 1);
end;
$$;
