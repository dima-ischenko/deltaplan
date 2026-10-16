-- Append-only log of dwa steps. Written only when initialize p_log_table is true.
do $ddl$
declare
    l_distributed      text := '';
    l_has_segment      boolean;
    l_has_slice        boolean;
    l_has_target_owner boolean;
begin
    if to_regclass('dwa_log') is null then
        if position('greenplum' in lower(version())) > 0 then
            l_distributed := ' distributed randomly';
        end if;

        execute
            'create table dwa_log (
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
        where attrelid = 'dwa_log'::regclass
          and attname = 'data_segment'
          and not attisdropped
    ) into l_has_segment;

    select exists (
        select 1
        from pg_attribute
        where attrelid = 'dwa_log'::regclass
          and attname = 'data_slice'
          and not attisdropped
    ) into l_has_slice;

    select exists (
        select 1
        from pg_attribute
        where attrelid = 'dwa_log'::regclass
          and attname = 'target_owner'
          and not attisdropped
    ) into l_has_target_owner;

    if l_has_segment and not l_has_slice then
        execute 'alter table dwa_log rename column data_segment to data_slice';
    end if;

    if not l_has_target_owner then
        execute 'alter table dwa_log add column target_owner text';
    end if;
end
$ddl$;

comment on table dwa_log is
    'Optional run log. initialize(..., p_log_table => true) writes a row per step in the caller transaction. Off by default.';
comment on column dwa_log.target_owner is
    'Schema of the target table at that step.';
comment on column dwa_log.data_slice is
    'Watermark slice of the run. Not a storage segment.';
comment on column dwa_log.message is
    'Same text as the notice, without the timestamp prefix.';
