-- Append-only log of dpl steps. Written only when set_log_table is on.
do $ddl$
declare
    l_distributed text := '';
begin
    if to_regclass('dpl_log') is not null then
        return;
    end if;

    if position('greenplum' in lower(version())) > 0 then
        l_distributed := ' distributed randomly';
    end if;

    execute
        'create table dpl_log (
            logged_at       timestamp   not null,
            proc_name       text        not null,
            target_table    text,
            data_segment    text,
            batch_no        numeric,
            log_rows        numeric,
            message         text
        )' || l_distributed;
end
$ddl$;

comment on table dpl_log is
    'Optional run log. set_log_table(true) writes a row per step in the caller transaction. Off by default.';
comment on column dpl_log.message is
    'Same text as the notice, without the timestamp prefix.';
