-- Keys to refresh. Rows survive commit and last until the session ends.
-- Target owner, target and slice of the run live in package state, not here.
-- source_owner and source_table stay: finalize advances one watermark per source.
--
-- Column order:
--   source_owner, source_table            — watermark grain within the run
--   pk_1, pk_2, pk_3                      — the business key, same order as dwv_batch_tmp
--   watermark                             — the source value of this key
--   batch_no, batch_done                  — progress, null and 0 until prepare_batches
create global temporary table dwv_keys_tmp (
    source_owner    varchar2(128) not null,
    source_table    varchar2(128) not null,
    pk_1            varchar2(255) not null,
    pk_2            varchar2(255),
    pk_3            varchar2(255),
    watermark       date          not null,
    batch_no        number,
    batch_done      number(1)     default 0 not null,
    constraint ck_dwv_keys_tmp_done check (batch_done in (0, 1))
) on commit preserve rows;

create index idx_dwv_keys_tmp_batch
    on dwv_keys_tmp (batch_no, batch_done);

comment on table dwv_keys_tmp is
    'Keys of the current run. Target and slice live in the session. A calculation without batches reads this table. prepare_batches fills batch_no.';
comment on column dwv_keys_tmp.source_owner is
    'Schema of the source that produced this key.';
comment on column dwv_keys_tmp.source_table is
    'Source that produced this key. finalize keeps the greatest watermark per source owner and name.';
comment on column dwv_keys_tmp.pk_1 is
    'First part of the business key. pk_2 and pk_3 are null when the key is shorter.';
comment on column dwv_keys_tmp.watermark is
    'Source value of this key. finalize keeps the greatest one per source.';
comment on column dwv_keys_tmp.batch_no is
    'Batch of a distinct (pk_1, pk_2, pk_3). The same key from several sources shares one batch. Null when batches are not used.';
comment on column dwv_keys_tmp.batch_done is
    '1 after finish_batch. The watermark has not moved yet.';
