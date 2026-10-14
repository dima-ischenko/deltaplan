create or replace package pkg_dpl is

    -- p_lookback_hours moves the read bound back by N hours; fractions are allowed.
    -- The source SQL keeps a strict predicate: value > :since.
    -- Zero leaves the bound equal to the stored watermark.
    -- dpl_watermark receives the watermark itself; the lookback offset is not stored.
    procedure initialize(
        p_target_table    varchar2,
        p_data_segment    varchar2 default 'all',
        p_lookback_hours  number   default 0,
        p_debug           boolean  default false
    );

    -- For capture and refresh SQL. Package variables are not visible in SQL.
    function get_target_table return varchar2;
    function get_data_segment return varchar2;

    -- The number of the batch that is open, or null when none is.
    function get_batch_no return number;

    -- Write each log line to dpl_log. Off by default.
    procedure set_log_table(p_enabled boolean default true);

    -- A null p_lookback_hours takes the value given to initialize.
    -- p_sql must contain :since exactly once.
    -- The placeholder is already the watermark minus the lookback offset.
    -- The statement must return pk_1 and watermark. pk_2 and pk_3 are optional.
    procedure capture_delta(
        p_source_table    varchar2,
        p_sql             varchar2,
        p_lookback_hours  number default null
    );

    -- Batches are optional. The target calculation is ordinary SQL.
    --
    -- Without batches it reads every key from dpl_keys_tmp
    -- and finalize is called immediately afterwards.
    -- The table holds only the current run. Target and segment
    -- in SQL are get_target_table and get_data_segment.
    --
    -- With batches: prepare_batches, then the loop
    -- next_batch / SQL against dpl_batch_tmp / finish_batch.
    -- dpl_batch_tmp holds only the keys of the current batch.
    -- When p_commit_batch is true, finish_batch commits that batch.
    -- finalize does not commit and does not advance the watermark
    -- while a batch is still unfinished. The caller commits after finalize.
    -- A failed run is repeated from initialize. The refresh statement
    -- has to be idempotent.
    procedure prepare_batches(
        p_batch_size    number  default 5000,
        p_commit_batch  boolean default true
    );

    -- Returns true when a batch is open and its keys are in dpl_batch_tmp.
    -- Returns false when no unfinished batch remains.
    -- Calling it again while the previous batch is still open and
    -- dpl_batch_tmp is not empty raises an error.
    -- A commit or rollback that empties dpl_batch_tmp while a batch is open
    -- raises an error. Call initialize and repeat the run.
    function next_batch return boolean;

    -- Marks the open batch complete.
    -- Commits when prepare_batches was called with p_commit_batch true.
    -- The log line records sql%rowcount of the preceding DML, so call this immediately after it.
    procedure finish_batch;

    -- Advances dpl_watermark from dpl_keys_tmp and clears the session.
    -- Does not commit. Refuses while a batch is still unfinished,
    -- and does not roll that error back.
    procedure finalize;

end pkg_dpl;
