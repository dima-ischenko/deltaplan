------- ddl_dml
drop table if exists :"dpl_schema".dpl_watermark;
drop table if exists dpl_keys_tmp;
drop table if exists dpl_batch_tmp;
drop table if exists dpl_session_tmp;

-- leftover names from earlier layouts
drop table if exists public.deltaplan_watermark;
drop table if exists deltaplan_keys_tmp;
drop table if exists deltaplan_batch_tmp;
drop table if exists deltaplan_session_tmp;
drop table if exists public.deltaplan_mark;
drop table if exists deltaplan_watermark;
drop table if exists deltaplan_mark;
drop table if exists deltaplan_keys;
drop table if exists deltaplan_key;
drop table if exists deltaplan_batch;

-- The fixed schema from an earlier install. Leave it in place when this
-- rollback is aimed at that schema: the drops above already removed the objects.
do $r$
begin
    if current_schema() is distinct from 'deltaplan' then
        drop schema if exists deltaplan cascade;
    end if;
end
$r$;
