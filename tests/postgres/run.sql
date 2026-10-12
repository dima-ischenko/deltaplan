-- Rebuild into schema lib (not public) and run the checks.
-- psql "postgresql://user:password@localhost:5432/db" -v ON_ERROR_STOP=1 -f tests/postgres/run.sql

\set ON_ERROR_STOP on
\set dpl_schema lib
drop schema if exists dpl_test cascade;
drop schema if exists lib cascade;
create schema lib;
\ir ../../lib/postgres/rollback.sql
\ir ../../lib/postgres/deploy.sql
set search_path to lib, public;

\ir helpers/tables.sql
\ir helpers/helpers.sql

delete from dpl_watermark
where target_table in ('inc_test_tgt', 'other_tgt');

\ir cases/static_without_batches.sql
\ir cases/lookback_window.sql
\ir cases/static_batches.sql
\ir cases/same_result.sql
\ir cases/rerun_after_failed_batch.sql
\ir cases/batch_guards.sql
\ir cases/one_pk_one_batch.sql
\ir cases/rollback_without_commit.sql
\ir cases/volume.sql

do $$ begin raise notice 'dpl_test: passed'; end; $$;

\ir demo/seed_customer_metrics.sql
\ir demo/example_customer_metrics.sql
\ir demo/check_customer_metrics.sql
