-- Permanent watermark in the current schema. deploy.sql sets search_path
-- to the install schema before this file runs.
-- On Greenplum the primary key must contain the distribution key, or
-- INSERT ... ON CONFLICT is rejected. target_table is that key.
do $ddl$
declare
    l_distributed       text := '';
    l_has_segment       boolean;
    l_has_slice         boolean;
    l_has_target_owner  boolean;
    l_has_source_owner  boolean;
    l_pk_def            text;
begin
    if position('greenplum' in lower(version())) > 0 then
        l_distributed := ' distributed by (target_table)';
    end if;

    if to_regclass('dwa_watermark') is null then
        execute
            'create table dwa_watermark (
                target_owner    text        not null default lower(current_schema()),
                target_table    text        not null,
                data_slice      text        not null default ''all'',
                source_owner    text        not null default lower(current_schema()),
                source_table    text        not null,
                watermark       timestamp   not null,
                updated_at      timestamp   not null,
                constraint pk_dwa_watermark primary key (
                    target_owner, target_table, data_slice, source_owner, source_table
                )
            )' || l_distributed;
        return;
    end if;

    select exists (
        select 1
        from pg_attribute
        where attrelid = 'dwa_watermark'::regclass
          and attname = 'data_segment'
          and not attisdropped
    ) into l_has_segment;

    select exists (
        select 1
        from pg_attribute
        where attrelid = 'dwa_watermark'::regclass
          and attname = 'data_slice'
          and not attisdropped
    ) into l_has_slice;

    select exists (
        select 1
        from pg_attribute
        where attrelid = 'dwa_watermark'::regclass
          and attname = 'target_owner'
          and not attisdropped
    ) into l_has_target_owner;

    select exists (
        select 1
        from pg_attribute
        where attrelid = 'dwa_watermark'::regclass
          and attname = 'source_owner'
          and not attisdropped
    ) into l_has_source_owner;

    if l_has_segment and not l_has_slice then
        execute 'alter table dwa_watermark rename column data_segment to data_slice';
    end if;

    if not l_has_target_owner then
        execute 'alter table dwa_watermark add column target_owner text';
        execute 'update dwa_watermark set target_owner = lower(current_schema()) where target_owner is null';
        execute 'alter table dwa_watermark alter column target_owner set default lower(current_schema())';
        execute 'alter table dwa_watermark alter column target_owner set not null';
    end if;

    if not l_has_source_owner then
        execute 'alter table dwa_watermark add column source_owner text';
        execute 'update dwa_watermark set source_owner = lower(current_schema()) where source_owner is null';
        execute 'alter table dwa_watermark alter column source_owner set default lower(current_schema())';
        execute 'alter table dwa_watermark alter column source_owner set not null';
    end if;

    select pg_get_constraintdef(oid)
    into l_pk_def
    from pg_constraint
    where conrelid = 'dwa_watermark'::regclass
      and contype = 'p'
      and conname = 'pk_dwa_watermark';

    if l_pk_def is null
       or position('target_owner' in l_pk_def) = 0
       or position('source_owner' in l_pk_def) = 0
       or position('data_slice' in l_pk_def) = 0 then
        if l_pk_def is not null then
            execute 'alter table dwa_watermark drop constraint pk_dwa_watermark';
        end if;
        execute
            'alter table dwa_watermark add constraint pk_dwa_watermark primary key (
                target_owner, target_table, data_slice, source_owner, source_table
            )';
    end if;
end
$ddl$;

comment on table dwa_watermark is
    'High-water mark of a finished run. finalize advances it and never moves it backwards.';
comment on column dwa_watermark.target_owner is
    'Schema of the target table. Defaults to the current schema when omitted.';
comment on column dwa_watermark.source_owner is
    'Schema of the source table. Defaults to the current schema when omitted.';
comment on column dwa_watermark.data_slice is
    'Independent watermark slice of this target. Not a storage segment.';
comment on column dwa_watermark.watermark is
    'Greatest source value fully applied for this target, slice and source. The read bound is this value minus the lookback, and that bound is not stored.';
comment on column dwa_watermark.updated_at is
    'When finalize last wrote this row.';
