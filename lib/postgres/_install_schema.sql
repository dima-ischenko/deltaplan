-- Pick the schema that deploy.sql and rollback.sql install into.
-- Pass -v dwa_schema=name, or leave it unset to use the session's current schema.
-- The schema must already exist. Start from the repository root.
\if :{?dwa_schema}
set search_path to :"dwa_schema";
\else
select current_schema() as dwa_schema \gset
\endif

do $dwa$
begin
    if current_schema() is null then
        raise exception 'install schema does not exist (search_path=%)', current_setting('search_path');
    end if;
end
$dwa$;
