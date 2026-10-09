-- Deltaplan for PostgreSQL, and for Greenplum 7.
-- The routines are functions. They do not commit: versions without
-- procedures, and Greenplum releases that forbid a commit inside a
-- function, can run this file. The caller commits.
--
-- The script does not use MERGE: Greenplum has none. A refresh statement is
-- an UPDATE and an INSERT, or INSERT ... ON CONFLICT where the server has it.
--
-- Objects are created in the current schema. deploy.sql selects it.
-- initialize creates the temporary tables dpl_keys_tmp and dpl_batch_tmp.
-- Their names match the Oracle installation, so the refresh statement can
-- read them unqualified.
-- dpl_watermark is permanent and holds the watermark.
-- Column order matches the Oracle tables. See oracle/ddl_dml/dpl_keys_tmp.sql.
--
-- PostgreSQL keeps session flags in dpl_session_tmp, also temporary.
-- If the transaction that called initialize is rolled back, the temporary
-- tables go with it. Call initialize again.

-- Older installs used procedures, and a few signatures have changed.
-- DROP PROCEDURE on a function of the same name raises, so drop the functions first.
drop function if exists :"dpl_schema".finalize();
drop function if exists :"dpl_schema".finish_batch(bigint);
drop function if exists :"dpl_schema".next_batch();
drop function if exists :"dpl_schema".prepare_batches(numeric);
drop function if exists :"dpl_schema".capture_delta(text, text, numeric);
drop function if exists :"dpl_schema".initialize(text, text, numeric);
drop function if exists :"dpl_schema"._batch_total();
drop function if exists :"dpl_schema"._unassigned();
drop function if exists :"dpl_schema"._unfinished();
drop function if exists :"dpl_schema".get_batch_no();
drop function if exists :"dpl_schema".get_lookback_hours();
drop function if exists :"dpl_schema".get_data_segment();
drop function if exists :"dpl_schema".get_target_table();
drop function if exists :"dpl_schema"._ensure_temp();
drop function if exists :"dpl_schema".apply_batches(text, numeric, boolean);
drop function if exists :"dpl_schema".prepare_batches(numeric, boolean);
drop function if exists :"dpl_schema".get_oversync_hours();

drop procedure if exists :"dpl_schema".apply_batches(text, numeric, boolean);
drop procedure if exists :"dpl_schema"._ensure_temp();
drop procedure if exists :"dpl_schema".initialize(text, text, numeric);
drop procedure if exists :"dpl_schema".capture_delta(text, text, numeric);
drop procedure if exists :"dpl_schema".prepare_batches(numeric, boolean);
drop procedure if exists :"dpl_schema".prepare_batches(numeric);
drop procedure if exists :"dpl_schema".finish_batch(bigint);
drop procedure if exists :"dpl_schema".finalize();
