-- Keys to refresh. Rows survive commit and last until the session ends.
--
-- Column order:
--   target_table, data_segment, source_table  — the same key as deltaplan_watermark
--   pk_1, pk_2, pk_3                          — the business key, same order as deltaplan_batch
--   watermark                                 — the source value of this key
--   batch_no, batch_done                      — progress, null and 0 until prepare_batches
create global temporary table deltaplan_keys (
    target_table    varchar2(128) not null,
    data_segment    varchar2(64)  not null,
    source_table    varchar2(128) not null,
    pk_1            varchar2(255) not null,
    pk_2            varchar2(255),
    pk_3            varchar2(255),
    watermark       date          not null,
    batch_no        number,
    batch_done      number(1)     default 0 not null,
    constraint ck_deltaplan_keys_batch_done check (batch_done in (0, 1))
) on commit preserve rows;

create index idx_deltaplan_keys_batch
    on deltaplan_keys (target_table, data_segment, batch_no, batch_done);

comment on table deltaplan_keys is
    'Keys of the current delta. A calculation without batches reads this table. prepare_batches fills batch_no.';
comment on column deltaplan_keys.pk_1 is
    'First part of the business key. pk_2 and pk_3 are null when the key is shorter.';
comment on column deltaplan_keys.watermark is
    'Source value of this key. finalize keeps the greatest one per source.';
comment on column deltaplan_keys.batch_no is
    'Batch of a distinct (pk_1, pk_2, pk_3). The same key from several sources shares one batch. Null when batches are not used.';
comment on column deltaplan_keys.batch_done is
    '1 after finish_batch. The watermark has not moved yet.';
