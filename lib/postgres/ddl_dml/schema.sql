-- Objects are created in the current schema. deploy.sql selects it.
-- initialize creates the temporary tables dwa_keys_tmp and dwa_batch_tmp.
-- dwa_watermark and dwa_log are permanent. set_log_table writes to dwa_log;
-- it stays empty by default.
-- Session flags live in dwa_session_tmp. If the transaction that called
-- initialize is rolled back, the temporary tables go with it.

-- Older installs used procedures, and a few signatures have changed.
-- DROP PROCEDURE on a function of the same name raises, so drop the functions first.
drop function if exists :"dwa_schema".finalize();
drop function if exists :"dwa_schema".set_log_table(boolean);
drop function if exists :"dwa_schema".set_debug(boolean);
drop function if exists :"dwa_schema".get_log_table();
drop function if exists :"dwa_schema".get_debug();
drop function if exists :"dwa_schema"._log(text, numeric, text);
drop function if exists :"dwa_schema"._debug();
drop function if exists :"dwa_schema".finish_batch(bigint);
drop function if exists :"dwa_schema".next_batch();
drop function if exists :"dwa_schema".prepare_batches(numeric);
drop function if exists :"dwa_schema".capture_delta(text, text, numeric);
drop function if exists :"dwa_schema".capture_delta(text, text, numeric, text);
drop function if exists :"dwa_schema".initialize(text, text, numeric);
drop function if exists :"dwa_schema".initialize(text, text, numeric, boolean);
drop function if exists :"dwa_schema".initialize(text, text, numeric, boolean, text);
drop function if exists :"dwa_schema"._batch_total();
drop function if exists :"dwa_schema"._unassigned();
drop function if exists :"dwa_schema"._unfinished();
drop function if exists :"dwa_schema".get_batch_no();
drop function if exists :"dwa_schema".get_lookback_hours();
drop function if exists :"dwa_schema".get_data_segment();
drop function if exists :"dwa_schema".get_data_slice();
drop function if exists :"dwa_schema".get_target_table();
drop function if exists :"dwa_schema".get_target_owner();
drop function if exists :"dwa_schema"._qualify_relation(text, text, text);
drop function if exists :"dwa_schema"._assert_relation(text, text);
drop function if exists :"dwa_schema"._norm_ident(text, text);
drop function if exists :"dwa_schema"._resolve_owner(text);
drop function if exists :"dwa_schema"._release_run_lock(text, text);
drop function if exists :"dwa_schema"._release_run_lock(text, text, text);
drop function if exists :"dwa_schema"._acquire_run_lock(text, text);
drop function if exists :"dwa_schema"._acquire_run_lock(text, text, text);
drop function if exists :"dwa_schema"._run_lock_held(integer);
drop function if exists :"dwa_schema"._run_lock_id(text, text);
drop function if exists :"dwa_schema"._ensure_temp();
drop function if exists :"dwa_schema".apply_batches(text, numeric, boolean);
drop function if exists :"dwa_schema".prepare_batches(numeric, boolean);
drop function if exists :"dwa_schema".get_oversync_hours();

drop procedure if exists :"dwa_schema".apply_batches(text, numeric, boolean);
drop procedure if exists :"dwa_schema"._ensure_temp();
drop procedure if exists :"dwa_schema".initialize(text, text, numeric);
drop procedure if exists :"dwa_schema".capture_delta(text, text, numeric);
drop procedure if exists :"dwa_schema".prepare_batches(numeric, boolean);
drop procedure if exists :"dwa_schema".prepare_batches(numeric);
drop procedure if exists :"dwa_schema".finish_batch(bigint);
drop procedure if exists :"dwa_schema".finalize();
