-- One row per target, segment and source.
-- Those three columns are the key, then the stored value, then when it was written.
create table dpl_watermark (
    target_table    varchar2(128) not null,
    data_segment    varchar2(64)  default 'all' not null,
    source_table    varchar2(128) not null,
    watermark       date          not null,
    updated_at      date          not null,
    constraint pk_dpl_watermark primary key (target_table, data_segment, source_table)
);

comment on table dpl_watermark is
    'High-water mark of a finished run. pkg_deltaplan.finalize advances it and never moves it backwards.';
comment on column dpl_watermark.watermark is
    'Greatest source value fully applied for this target, segment and source. The read bound is this value minus the lookback, and that bound is not stored.';
comment on column dpl_watermark.updated_at is
    'When finalize last wrote this row.';
