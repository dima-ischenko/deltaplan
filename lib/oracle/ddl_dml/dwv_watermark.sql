-- One row per target owner, target, slice, source owner and source.
-- Those five columns are the key, then the stored value, then when it was written.
create table dwv_watermark (
    target_owner    varchar2(128) default lower(sys_context('USERENV', 'CURRENT_SCHEMA')) not null,
    target_table    varchar2(128) not null,
    data_slice      varchar2(64)  default 'all' not null,
    source_owner    varchar2(128) default lower(sys_context('USERENV', 'CURRENT_SCHEMA')) not null,
    source_table    varchar2(128) not null,
    watermark       date          not null,
    updated_at      date          not null,
    constraint pk_dwv_watermark primary key (
        target_owner, target_table, data_slice, source_owner, source_table
    )
);

comment on table dwv_watermark is
    'High-water mark of a finished run. pkg_dwv.finalize advances it and never moves it backwards.';
comment on column dwv_watermark.target_owner is
    'Schema of the target table. Defaults to the current schema when omitted.';
comment on column dwv_watermark.source_owner is
    'Schema of the source table. Defaults to the current schema when omitted.';
comment on column dwv_watermark.data_slice is
    'Independent watermark slice of this target. Not a storage segment.';
comment on column dwv_watermark.watermark is
    'Greatest source value fully applied for this target, slice and source. The read bound is this value minus the lookback, and that bound is not stored.';
comment on column dwv_watermark.updated_at is
    'When finalize last wrote this row.';
