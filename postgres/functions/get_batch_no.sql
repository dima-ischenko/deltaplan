-- The number of the batch that is open, or null when none is.
create or replace function get_batch_no()
returns numeric
language plpgsql stable
set search_path = pg_temp, :"dpl_schema", public as $$
begin
    if to_regclass('dpl_session_tmp') is null then
        return null;
    end if;
    return (select batch_no from dpl_session_tmp where id = 1);
end;
$$;
