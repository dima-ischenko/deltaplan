create or replace function deltaplan._ensure_temp()
returns void
language plpgsql
set search_path = pg_temp, public as $$
declare
    l_by_id  text := '';
    l_by_pk  text := '';
begin
    -- PostgreSQL rejects DISTRIBUTED BY. Greenplum needs it: the primary key
    -- of deltaplan_session_tmp has to contain the distribution key, and the key
    -- tables are distributed by pk_1, the column the calculation joins.
    if position('greenplum' in lower(version())) > 0 then
        l_by_id := ' distributed by (id)';
        l_by_pk := ' distributed by (pk_1)';
    end if;

    execute format($sql$
        create temp table if not exists deltaplan_session_tmp (
            id              int primary key,
            target_table    text,
            data_segment    text,
            lookback_hours  numeric,
            batch_no        numeric,
            batch_size      numeric,
            batches_ready   boolean,
            apply_open      boolean,
            constraint ck_deltaplan_session_tmp_id check (id = 1)
        ) on commit preserve rows%s
    $sql$, l_by_id);

    execute format($sql$
        create temp table if not exists deltaplan_keys_tmp (
            target_table    text        not null,
            data_segment    text        not null,
            source_table    text        not null,
            pk_1            text        not null,
            pk_2            text,
            pk_3            text,
            watermark       timestamp   not null,
            batch_no        numeric,
            batch_done      smallint    not null default 0,
            constraint ck_deltaplan_keys_tmp_done check (batch_done in (0, 1))
        ) on commit preserve rows%s
    $sql$, l_by_pk);

    execute format($sql$
        create temp table if not exists deltaplan_batch_tmp (
            pk_1            text        not null,
            pk_2            text,
            pk_3            text
        ) on commit delete rows%s
    $sql$, l_by_pk);

    create index if not exists idx_deltaplan_keys_tmp_batch
        on deltaplan_keys_tmp (target_table, data_segment, batch_no, batch_done);
end;
$$;
