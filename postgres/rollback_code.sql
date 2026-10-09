------- functions
drop function if exists deltaplan.finalize();
drop function if exists deltaplan.finish_batch(bigint);
drop function if exists deltaplan.next_batch();
drop function if exists deltaplan.prepare_batches(numeric);
drop function if exists deltaplan.capture_delta(text, text, numeric);
drop function if exists deltaplan.initialize(text, text, numeric);
drop function if exists deltaplan._batch_total();
drop function if exists deltaplan._unassigned();
drop function if exists deltaplan._unfinished();
drop function if exists deltaplan.get_batch_no();
drop function if exists deltaplan.get_lookback_hours();
drop function if exists deltaplan.get_data_segment();
drop function if exists deltaplan.get_target_table();
drop function if exists deltaplan._ensure_temp();

-- leftover names from earlier layouts
drop function if exists deltaplan.apply_batches(text, numeric, boolean);
drop function if exists deltaplan.prepare_batches(numeric, boolean);
drop function if exists deltaplan.get_oversync_hours();

drop procedure if exists deltaplan.apply_batches(text, numeric, boolean);
drop procedure if exists deltaplan._ensure_temp();
drop procedure if exists deltaplan.initialize(text, text, numeric);
drop procedure if exists deltaplan.capture_delta(text, text, numeric);
drop procedure if exists deltaplan.prepare_batches(numeric, boolean);
drop procedure if exists deltaplan.prepare_batches(numeric);
drop procedure if exists deltaplan.finish_batch(bigint);
drop procedure if exists deltaplan.finalize();
