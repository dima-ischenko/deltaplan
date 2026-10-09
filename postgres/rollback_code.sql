------- functions
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

-- leftover names from earlier layouts
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
