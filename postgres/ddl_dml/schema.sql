-- Deltaplan for PostgreSQL, and for Greenplum 7.
-- The routines are functions. They do not commit: versions without
-- procedures, and Greenplum releases that forbid a commit inside a
-- function, can run this file. The caller commits.
--
-- The script does not use MERGE: Greenplum has none. A target statement is
-- an UPDATE and an INSERT, or INSERT ... ON CONFLICT where the server has it.
--
-- The calculating session calls deltaplan.initialize, which creates the
-- temporary tables deltaplan_keys_tmp and deltaplan_batch_tmp. Their names match the
-- Oracle installation, so the target statement can read them unqualified.
-- deltaplan_watermark is permanent and holds the watermark.
-- Column order matches the Oracle tables. See oracle/ddl_dml/deltaplan_keys_tmp.sql.
--
-- PostgreSQL keeps session flags in deltaplan_session_tmp, also temporary.
-- If the transaction that called initialize is rolled back, the temporary
-- tables go with it. Call initialize again.

create schema if not exists deltaplan;

-- Older installs used procedures that committed. DROP PROCEDURE on a function
-- of the same name raises, so drop the functions first.
drop function if exists deltaplan.apply_batches(text, numeric, boolean);
drop function if exists deltaplan._ensure_temp();
drop function if exists deltaplan.initialize(text, text, numeric);
drop function if exists deltaplan.capture_delta(text, text, numeric);
drop function if exists deltaplan.prepare_batches(numeric, boolean);
drop function if exists deltaplan.prepare_batches(numeric);
drop function if exists deltaplan.finish_batch(bigint);
drop function if exists deltaplan.finalize();
drop function if exists deltaplan.get_oversync_hours();

drop procedure if exists deltaplan.apply_batches(text, numeric, boolean);
drop procedure if exists deltaplan._ensure_temp();
drop procedure if exists deltaplan.initialize(text, text, numeric);
drop procedure if exists deltaplan.capture_delta(text, text, numeric);
drop procedure if exists deltaplan.prepare_batches(numeric, boolean);
drop procedure if exists deltaplan.prepare_batches(numeric);
drop procedure if exists deltaplan.finish_batch(bigint);
drop procedure if exists deltaplan.finalize();
