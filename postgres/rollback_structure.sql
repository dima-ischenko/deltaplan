------- ddl_dml
drop table if exists public.deltaplan_watermark;
drop table if exists deltaplan_keys_tmp;
drop table if exists deltaplan_batch_tmp;
drop table if exists deltaplan_session_tmp;

-- leftover names from earlier layouts
drop table if exists public.deltaplan_mark;
drop table if exists deltaplan_watermark;
drop table if exists deltaplan_mark;
drop table if exists deltaplan_keys;
drop table if exists deltaplan_key;
drop table if exists deltaplan_batch;

drop schema if exists deltaplan;
