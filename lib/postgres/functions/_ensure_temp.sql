create or replace function _ensure_temp()
returns void
language plpgsql
set search_path = pg_temp, :"dpl_schema", public as $$
declare
l_by_id  text := '';
l_by_pk  text := '';
begin
  -- Greenplum: PK must include the distribution key; keys are distributed by pk_1.
  if position('greenplum' in lower(version())) > 0 then
    l_by_id := ' distributed by (id)';
    l_by_pk := ' distributed by (pk_1)';
  end if;

  execute format($sql$
    create temp table if not exists dpl_session_tmp (
      id              int primary key,
      target_table    text,
      data_segment    text,
      lookback_hours  numeric,
      batch_no        numeric,
      batch_size      numeric,
      batches_ready   boolean,
      debug           boolean not null default false,
      log_table       boolean not null default false,
      constraint ck_dpl_session_tmp_id check (id = 1)
    ) on commit preserve rows%s
  $sql$, l_by_id);

  if to_regclass('dpl_session_tmp') is not null
   and not exists (
     select 1
     from pg_attribute
     where attrelid = to_regclass('dpl_session_tmp')
      and attname = 'debug'
      and not attisdropped
   ) then
    alter table dpl_session_tmp add column debug boolean not null default false;
    alter table dpl_session_tmp add column log_table boolean not null default false;
  end if;

  -- An older session may still have target_table / data_segment on the keys
  -- table. Those belong in dpl_session_tmp; drop and recreate.
  if to_regclass('dpl_keys_tmp') is not null
   and exists (
     select 1
     from pg_attribute
     where attrelid = to_regclass('dpl_keys_tmp')
      and attname = 'target_table'
      and not attisdropped
   ) then
    drop table dpl_keys_tmp;
  end if;

  execute format($sql$
    create temp table if not exists dpl_keys_tmp (
      source_table    text        not null,
      pk_1            text        not null,
      pk_2            text,
      pk_3            text,
      watermark       timestamp   not null,
      batch_no        numeric,
      batch_done      smallint    not null default 0,
      constraint ck_dpl_keys_tmp_done check (batch_done in (0, 1))
    ) on commit preserve rows%s
  $sql$, l_by_pk);

  execute format($sql$
    create temp table if not exists dpl_batch_tmp (
      pk_1            text        not null,
      pk_2            text,
      pk_3            text
    ) on commit delete rows%s
  $sql$, l_by_pk);

  create index if not exists idx_dpl_keys_tmp_batch
    on dpl_keys_tmp (batch_no, batch_done);
end;
$$;
