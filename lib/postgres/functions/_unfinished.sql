-- These read the session's temporary tables, which do not exist until initialize.
create or replace function _unfinished()
returns integer
language plpgsql stable
set search_path = pg_temp, :"dpl_schema", public as $$
begin
    if exists (
        select 1
        from dpl_keys_tmp
        where batch_no is not null
          and batch_done = 0
    ) then
        return 1;
    end if;
    return 0;
end;
$$;
