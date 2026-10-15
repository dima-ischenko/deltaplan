-- Append-only log of dwv steps. Written only when set_log_table is on.
do $ddl$
declare
    l_distributed      text := '';
    l_has_segment      boolean;
    l_has_slice        boolean;
    l_has_target_owner boolean;
begin
    if to_regclass('dwv_log') is null then
        if position('greenplum' in lower(version())) > 0 then
            l_distributed := ' distributed randomly';
        end if;

        execute
            'create table dwv_log (
                logged_at       timestamp   not null,
                proc_name       text        not null,
                target_owner    text,
                target_table    text,
                data_slice      text,
                batch_no        numeric,
                log_rows        numeric,
                message         text
            )' || l_distributed;
        return;
    end if;

    select exists (
        select 1
        from pg_attribute
        where attrelid = 'dwv_log'::regclass
          and attname = 'data_segment'
          and not attisdropped
    ) into l_has_segment;

    select exists (
        select 1
        from pg_attribute
        where attrelid = 'dwv_log'::regclass
          and attname = 'data_slice'
          and not attisdropped
    ) into l_has_slice;

    select exists (
        select 1
        from pg_attribute
        where attrelid = 'dwv_log'::regclass
          and attname = 'target_owner'
          and not attisdropped
    ) into l_has_target_owner;

    if l_has_segment and not l_has_slice then
        execute 'alter table dwv_log rename column data_segment to data_slice';
    end if;

    if not l_has_target_owner then
        execute 'alter table dwv_log add column target_owner text';
    end if;
end
$ddl$;

comment on table dwv_log is
    'Optional run log. set_log_table(true) writes a row per step in the caller transaction. Off by default.';
comment on column dwv_log.target_owner is
    'Schema of the target table at that step.';
comment on column dwv_log.data_slice is
    'Watermark slice of the run. Not a storage segment.';
comment on column dwv_log.message is
    'Same text as the notice, without the timestamp prefix.';
