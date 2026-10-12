-- Pick the schema that deploy.sql and rollback.sql install into.
-- Pass -v dpl_schema=name, or leave it unset to use the session's current schema.
-- The schema must already exist. psql resolves \ir against this file's directory.
\if :{?dpl_schema}
set search_path to :"dpl_schema";
\else
select current_schema() as dpl_schema \gset
\endif

do $dpl$
begin
    if current_schema() is null then
        raise exception 'install schema does not exist (search_path=%)', current_setting('search_path');
    end if;
end
$dpl$;
