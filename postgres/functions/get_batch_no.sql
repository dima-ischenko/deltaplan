-- The number of the batch that is open, or null when none is.
create or replace function deltaplan.get_batch_no()
returns numeric
language plpgsql stable
set search_path = pg_temp, public as $$
begin
    if to_regclass('deltaplan_session_tmp') is null then
        return null;
    end if;
    return (select batch_no from deltaplan_session_tmp where id = 1);
end;
$$;
