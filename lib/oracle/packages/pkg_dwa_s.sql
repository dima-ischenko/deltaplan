create or replace package pkg_dwa is

  -- p_owner defaults to sys_context('USERENV', 'CURRENT_SCHEMA').
  -- The target must exist and be selectable by the caller.
  -- p_lookback_hours moves the read bound back by N hours.
  -- Zero uses the stored watermark. The lookback is not written to dwa_watermark.
  -- Exclusive named DBMS_LOCK on (owner, target, slice). Another session gets -20021.
  -- The lock survives commit and is released in finalize, or when the session ends.
  -- p_log_table writes each step to dwa_log. Off by default.
  procedure initialize(
      p_target_table    varchar2,
      p_owner           varchar2 default null,
      p_data_slice      varchar2 default 'all',
      p_lookback_hours  number   default 0,
      p_debug           boolean  default false,
      p_log_table       boolean  default false
  );

  -- p_owner defaults to the current schema. The source must exist and be
  -- selectable. Watermarks are stored per (source owner, source table).
  -- A null p_lookback_hours takes the value given to initialize.
  -- p_sql must contain :since. :data_slice is optional.
  -- :since is the stored watermark minus the lookback.
  -- The statement must return pk_1 and watermark. pk_2 and pk_3 are optional.
  procedure capture_delta(
      p_source_table    varchar2,
      p_owner           varchar2 default null,
      p_sql             varchar2,
      p_lookback_hours  number default null
  );

  -- Batches are optional. The target calculation is ordinary SQL.
  --
  -- Without batches it reads every key from dwa_keys_tmp
  -- and finalize is called immediately afterwards.
  -- The table holds only the current run. Target and slice
  -- are the values given to initialize.
  --
  -- With batches: prepare_batches, then the loop
  -- next_batch / SQL against dwa_batch_tmp / finish_batch.
  -- dwa_batch_tmp holds only the keys of the current batch.
  -- When p_commit_batch is true, finish_batch commits that batch.
  -- finalize does not commit and does not advance the watermark
  -- while a batch is still unfinished. The caller commits after finalize.
  -- A failed run is repeated from initialize. The refresh statement
  -- has to be idempotent.
  procedure prepare_batches(
      p_batch_size    number  default 5000,
      p_commit_batch  boolean default true
  );

  -- Returns true when a batch is open and its keys are in dwa_batch_tmp.
  -- Returns false when no unfinished batch remains.
  -- Calling it again while the previous batch is still open and
  -- dwa_batch_tmp is not empty raises an error.
  -- A commit or rollback that empties dwa_batch_tmp while a batch is open
  -- raises an error. Call initialize and repeat the run.
  function next_batch return boolean;

  -- Marks the open batch complete.
  -- Commits when prepare_batches was called with p_commit_batch true.
  -- The log line records sql%rowcount of the preceding DML, so call this immediately after it.
  procedure finish_batch;

  -- Advances dwa_watermark from dwa_keys_tmp, releases the run lock,
  -- and clears the session. Does not commit. Refuses while a batch is
  -- still unfinished, and does not roll that error back.
  procedure finalize;

end pkg_dwa;
