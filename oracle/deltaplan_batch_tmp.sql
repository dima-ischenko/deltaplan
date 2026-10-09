-- Keys of the batch opened by next_batch.
-- pk_1, pk_2, pk_3 are in the same order as deltaplan_keys_tmp.
-- Commit empties the table, so the next batch cannot see the previous one.
create global temporary table deltaplan_batch_tmp (
    pk_1            varchar2(255) not null,
    pk_2            varchar2(255),
    pk_3            varchar2(255)
) on commit delete rows;

comment on table deltaplan_batch_tmp is
    'Keys of the open batch. The target statement reads this table, not the whole of deltaplan_keys_tmp.';
