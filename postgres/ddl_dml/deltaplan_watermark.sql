-- Permanent, so the name is schema-qualified. A role search_path of
-- "$user", public would otherwise create a second copy beside public.
-- On Greenplum the primary key must contain the distribution key, or
-- INSERT ... ON CONFLICT is rejected. target_table is that key.
do $ddl$
declare
    l_distributed text := '';
begin
    if to_regclass('public.deltaplan_watermark') is not null then
        return;
    end if;

    if position('greenplum' in lower(version())) > 0 then
        l_distributed := ' distributed by (target_table)';
    end if;

    execute
        'create table public.deltaplan_watermark (
            target_table    text        not null,
            data_segment    text        not null default ''all'',
            source_table    text        not null,
            watermark       timestamp   not null,
            updated_at      timestamp   not null,
            constraint pk_deltaplan_watermark primary key (target_table, data_segment, source_table)
        )' || l_distributed;
end
$ddl$;

comment on table public.deltaplan_watermark is
    'High-water mark of a finished run. deltaplan.finalize advances it and never moves it backwards.';
comment on column public.deltaplan_watermark.watermark is
    'Greatest source value fully applied for this target, segment and source. The read bound is this value minus the lookback, and that bound is not stored.';
comment on column public.deltaplan_watermark.updated_at is
    'When finalize last wrote this row.';

