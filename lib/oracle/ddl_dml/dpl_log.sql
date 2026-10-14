-- Append-only log of pkg_dpl steps. Written only when set_log_table is on.
create table dpl_log (
    logged_at       timestamp     not null,
    proc_name       varchar2(64)  not null,
    target_table    varchar2(128),
    data_segment    varchar2(64),
    batch_no        number,
    log_rows        number,
    message         varchar2(4000)
);

comment on table dpl_log is
    'Optional run log. pkg_dpl.set_log_table(true) writes a row per step in an autonomous transaction. Off by default.';
comment on column dpl_log.message is
    'Same text as the dbms_output line, without the timestamp prefix.';
