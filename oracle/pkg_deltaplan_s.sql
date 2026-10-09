create or replace package pkg_deltaplan is

    -- p_lookback_hours moves the read bound back by N hours; fractions are allowed.
    -- The source SQL keeps a strict predicate: value > :since.
    -- Zero leaves the bound equal to the stored watermark.
    -- deltaplan_watermark receives the watermark itself; the lookback offset is not stored.
    procedure initialize(
        p_target_table    varchar2,
        p_data_segment    varchar2 default 'all',
        p_lookback_hours  number   default 0
    );

    function get_target_table return varchar2;

    function get_data_segment return varchar2;

    function get_lookback_hours return number;

    -- The number of the batch that is open, or null when none is.
    function get_batch_no return number;

    -- A null p_lookback_hours takes the value given to initialize.
    -- p_sql must contain :since exactly once.
    -- The placeholder is already the watermark minus the lookback offset.
    procedure capture_delta(
        p_source_table    varchar2,
        p_sql             varchar2,
        p_lookback_hours  number default null
    );

    -- Batches are optional. The target calculation is ordinary SQL.
    --
    -- Without batches it reads every key from deltaplan_keys
    -- (target_table = get_target_table and data_segment = get_data_segment)
    -- and finalize is called immediately afterwards.
    --
    -- With batches: prepare_batches, then the loop
    -- next_batch / SQL against deltaplan_batch / finish_batch.
    -- deltaplan_batch holds only the keys of the current batch.
    -- When p_commit is true, the captured keys are committed first,
    -- and each finish_batch commits its own batch.
    -- A later call in the same session resumes at the unfinished batch.
    -- finalize does not advance the watermark while such a batch remains.
    procedure prepare_batches(
        p_batch_size  number  default 5000,
        p_commit      boolean default true
    );

    -- Returns true when a batch is open and its keys are in deltaplan_batch.
    -- Returns false when no unfinished batch remains.
    -- Calling it again while the previous batch is still open and
    -- deltaplan_batch is not empty raises an error.
    -- After rollback, deltaplan_batch is empty and the next call returns the same batch.
    function next_batch return boolean;

    -- Marks the open batch complete.
    -- Commits when prepare_batches was called with p_commit true.
    -- The log line records sql%rowcount of the preceding DML, so call this immediately after it.
    procedure finish_batch;

    -- Advances deltaplan_watermark from deltaplan_keys and clears the session.
    -- Refuses while a batch is still unfinished, and does not roll that error back.
    procedure finalize;

end pkg_deltaplan;
