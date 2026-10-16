-- Open keys are recalculated every run (tcf debt on unclosed loans: date_to is null).
-- A soft delete is a tombstone whose watermark moves; the refresh drops the target row.
-- Stale watermarks on open keys must not pull dwa_watermark backwards.
-- Refresh reads dwa_batch_tmp only. PostgreSQL does not commit inside finish_batch.

create or replace function dwa_test.roll_wm()
returns text
language plpgsql stable as $$
declare
    l_value timestamp;
begin
    select watermark
      into l_value
      from dwa_watermark
     where target_table = 'inc_test_debt'
       and data_slice = 'all'
       and source_table = 'inc_test_roll';
    if not found then
        return null;
    end if;
    return to_char(l_value, 'YYYY-MM-DD HH24:MI:SS');
end;
$$;

create or replace function dwa_test.roll_debt()
returns text
language sql stable as $$
    select string_agg(
               id || ':' || to_char(amount, 'FM999999') || ':' || to_char(as_of, 'YYYY-MM-DD'),
               ',' order by id
           )
      from inc_test_debt
$$;

create or replace procedure dwa_test.apply_roll(
    p_step text,
    p_as_of date,
    p_batch_size integer,
    p_keys text,
    p_batches text,
    p_debt text,
    p_wm text,
    p_wm_before text,
    p_min_wm text
)
language plpgsql as $$
declare
    c_capture constant text := $sql$
        select id as pk_1,
               case
                   when deleted_at is not null then deleted_at
                   else updated_at
               end as watermark
          from inc_test_roll
         where (deleted_at is null and (updated_at > :since or closed_at is null))
            or (deleted_at is not null and deleted_at > :since)
    $sql$;
    l_keys text;
    l_min_wm text;
    l_batches integer := 0;
begin
    perform initialize(
        p_target_table => 'inc_test_debt',
        p_data_slice => 'all',
        p_lookback_hours => 0
    );
    perform capture_delta(
        p_source_table => 'inc_test_roll',
        p_sql => c_capture
    );

    select string_agg(pk_1, ',' order by pk_1)
      into l_keys
      from (select distinct pk_1 from dwa_keys_tmp) k;

    select to_char(min(watermark), 'YYYY-MM-DD HH24:MI:SS')
      into l_min_wm
      from dwa_keys_tmp;

    call dwa_test.eq(p_step || ' keys', l_keys, p_keys);
    call dwa_test.eq(p_step || ' min wm', l_min_wm, p_min_wm);
    call dwa_test.eq(p_step || ' wm before', dwa_test.roll_wm(), p_wm_before);

    perform prepare_batches(p_batch_size => p_batch_size);
    while next_batch() loop
        l_batches := l_batches + 1;

        delete from inc_test_debt d
         where exists (
             select 1 from dwa_batch_tmp k where k.pk_1 = d.id
         );

        insert into inc_test_debt (id, as_of, amount)
        select r.id, p_as_of, r.amount
          from inc_test_roll r
          join dwa_batch_tmp k on k.pk_1 = r.id
         where r.deleted_at is null;

        perform finish_batch();
    end loop;

    call dwa_test.eq(p_step || ' batches', l_batches::text, p_batches);
    perform finalize();
    call dwa_test.eq(p_step || ' debt', dwa_test.roll_debt(), p_debt);
    call dwa_test.eq(p_step || ' wm', dwa_test.roll_wm(), p_wm);
end;
$$;

create or replace procedure dwa_test.rolling_and_soft_delete()
language plpgsql as $$
declare
    c_open  constant timestamp := timestamp '2024-06-01 08:00:00';
    c_close constant timestamp := timestamp '2024-06-02 09:00:00';
    c_del   constant timestamp := timestamp '2024-06-03 10:00:00';
begin
    delete from dwa_watermark where target_table = 'inc_test_debt';
    delete from inc_test_debt;
    delete from inc_test_roll;

    insert into inc_test_roll (id, amount, updated_at, closed_at, deleted_at)
    values ('a', 100, c_open, null, null);
    insert into inc_test_roll (id, amount, updated_at, closed_at, deleted_at)
    values ('b', 40, c_open, null, null);
    insert into inc_test_roll (id, amount, updated_at, closed_at, deleted_at)
    values ('c', 7, c_open, null, null);

    -- Day 1: every open key, including ones that share a watermark.
    call dwa_test.apply_roll(
        'roll day1', date '2024-06-01', 2,
        'a,b,c', '2',
        'a:100:2024-06-01,b:40:2024-06-01,c:7:2024-06-01',
        '2024-06-01 08:00:00', null, '2024-06-01 08:00:00'
    );

    -- b closes. a and c are still open, so they are rebuilt for the new day.
    update inc_test_roll
       set closed_at = date '2024-06-02',
           updated_at = c_close
     where id = 'b';

    call dwa_test.apply_roll(
        'roll close', date '2024-06-02', 2,
        'a,b,c', '2',
        'a:100:2024-06-02,b:40:2024-06-02,c:7:2024-06-02',
        '2024-06-02 09:00:00', '2024-06-01 08:00:00', '2024-06-01 08:00:00'
    );

    -- Nothing changed. Open keys come back with a watermark older than the stored one.
    -- b stays on the day it closed. The watermark does not move back.
    call dwa_test.apply_roll(
        'roll open', date '2024-06-03', 1,
        'a,c', '2',
        'a:100:2024-06-03,b:40:2024-06-02,c:7:2024-06-03',
        '2024-06-02 09:00:00', '2024-06-02 09:00:00', '2024-06-01 08:00:00'
    );

    -- Soft delete of an open key. The tombstone is captured; the debt row goes away.
    update inc_test_roll
       set deleted_at = c_del
     where id = 'a';

    call dwa_test.apply_roll(
        'roll delete', date '2024-06-04', 1,
        'a,c', '2',
        'b:40:2024-06-02,c:7:2024-06-04',
        '2024-06-03 10:00:00', '2024-06-02 09:00:00', '2024-06-01 08:00:00'
    );

    -- Next day the deleted key is not resurrected. c, still open, moves forward.
    call dwa_test.apply_roll(
        'roll after delete', date '2024-06-05', 1,
        'c', '1',
        'b:40:2024-06-02,c:7:2024-06-05',
        '2024-06-03 10:00:00', '2024-06-03 10:00:00', '2024-06-01 08:00:00'
    );

    -- Clearing the tombstone without a newer updated_at: the open predicate brings a back.
    -- Its old watermark must not pull the stored watermark back to June 1.
    update inc_test_roll
       set deleted_at = null
     where id = 'a';

    call dwa_test.apply_roll(
        'roll restore', date '2024-06-05', 1,
        'a,c', '2',
        'a:100:2024-06-05,b:40:2024-06-02,c:7:2024-06-05',
        '2024-06-03 10:00:00', '2024-06-03 10:00:00', '2024-06-01 08:00:00'
    );

    call dwa_test.pass('rolling_and_soft_delete');
end;
$$;

call dwa_test.rolling_and_soft_delete();
