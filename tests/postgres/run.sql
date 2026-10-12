-- Rebuild into schema lib (not public) and run the checks.
-- From the repository root:
-- psql "postgresql://user:password@localhost:5432/db" -v ON_ERROR_STOP=1 -f tests/postgres/run.sql

\set ON_ERROR_STOP on
\set dpl_schema lib
drop schema if exists dpl_test cascade;
drop schema if exists lib cascade;
create schema lib;
\i lib/postgres/rollback.sql
\i lib/postgres/deploy.sql
set search_path to lib, public;

\i tests/postgres/helpers/tables.sql
\i tests/postgres/helpers/helpers.sql

delete from dpl_watermark
where target_table in ('inc_test_tgt', 'other_tgt');

\i tests/postgres/cases/static_without_batches.sql
\i tests/postgres/cases/lookback_window.sql
\i tests/postgres/cases/static_batches.sql
\i tests/postgres/cases/same_result.sql
\i tests/postgres/cases/rerun_after_failed_batch.sql
\i tests/postgres/cases/batch_guards.sql
\i tests/postgres/cases/one_pk_one_batch.sql
\i tests/postgres/cases/rollback_without_commit.sql
\i tests/postgres/cases/volume.sql

do $$ begin raise notice 'dpl_test: passed'; end; $$;

\i demo/postgres/tables.sql
\i demo/postgres/seed.sql
\i demo/postgres/run.sql
\i demo/postgres/check.sql

do $check$
declare
    l_metrics integer;
    l_wm      integer;
begin
    select count(*) into l_metrics from customer_metrics;
    select count(*)
    into l_wm
    from dpl_watermark
    where target_table = 'customer_metrics'
      and data_segment = 'all';

    if l_metrics is distinct from 3 then
        raise exception 'demo metrics=%, expected 3', l_metrics;
    end if;
    if l_wm is distinct from 3 then
        raise exception 'demo watermarks=%, expected 3', l_wm;
    end if;

    raise notice 'demo: passed';
end;
$check$;
