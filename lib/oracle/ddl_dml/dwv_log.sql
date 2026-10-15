-- Append-only log of pkg_dwv steps. Written only when set_log_table is on.
create table dwv_log (
    logged_at       timestamp     not null,
    proc_name       varchar2(64)  not null,
    target_owner    varchar2(128),
    target_table    varchar2(128),
    data_slice      varchar2(64),
    batch_no        number,
    log_rows        number,
    message         varchar2(4000)
);

comment on table dwv_log is
    'Optional run log. pkg_dwv.set_log_table(true) writes a row per step in an autonomous transaction. Off by default.';
comment on column dwv_log.target_owner is
    'Schema of the target table at that step.';
comment on column dwv_log.data_slice is
    'Watermark slice of the run. Not a storage segment.';
comment on column dwv_log.message is
    'Same text as the dbms_output line, without the timestamp prefix.';
