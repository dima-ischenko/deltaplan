-- Open keys are recalculated every run (tcf debt on unclosed loans: date_to is null).
-- A soft delete is a tombstone whose watermark moves; the refresh drops the target row.
-- Stale watermarks on open keys must not pull dwa_watermark backwards.
-- Refresh reads dwa_batch_tmp only, and finish_batch commits each batch.
declare
    c_open  constant date := timestamp '2024-06-01 08:00:00';
    c_close constant date := timestamp '2024-06-02 09:00:00';
    c_del   constant date := timestamp '2024-06-03 10:00:00';
    c_capture constant varchar2(1000) := q'[
        select id as pk_1,
               case
                   when deleted_at is not null then deleted_at
                   else updated_at
               end as watermark
          from inc_test_roll
         where (deleted_at is null and (updated_at > :since or closed_at is null))
            or (deleted_at is not null and deleted_at > :since)
    ]';

    function wm return varchar2 is
        l_value date;
    begin
        select watermark
          into l_value
          from dwa_watermark
         where target_table = 'inc_test_debt'
           and data_slice = 'all'
           and source_table = 'inc_test_roll';
        return to_char(l_value, 'YYYY-MM-DD HH24:MI:SS');
    exception
        when no_data_found then
            return null;
    end wm;

    function debt_state return varchar2 is
        l_value varchar2(4000);
    begin
        select listagg(
                   id || ':' || to_char(amount, 'FM999999') || ':' || to_char(as_of, 'YYYY-MM-DD'),
                   ','
               ) within group (order by id)
          into l_value
          from inc_test_debt;
        return l_value;
    end debt_state;

    procedure apply(
        p_step       varchar2,
        p_as_of      date,
        p_batch_size number,
        p_keys       varchar2,
        p_batches    varchar2,
        p_debt       varchar2,
        p_wm         varchar2,
        p_wm_before  varchar2,
        p_min_wm     varchar2
    ) is
        l_keys    varchar2(4000);
        l_min_wm  varchar2(40);
        l_batches number := 0;
    begin
        pkg_dwa.initialize(
            p_target_table   => 'inc_test_debt',
            p_data_slice     => 'all',
            p_lookback_hours => 0
        );
        pkg_dwa.capture_delta(
            p_source_table => 'inc_test_roll',
            p_sql          => c_capture
        );

        select listagg(pk_1, ',') within group (order by pk_1)
          into l_keys
          from (select distinct pk_1 from dwa_keys_tmp);

        select to_char(min(watermark), 'YYYY-MM-DD HH24:MI:SS')
          into l_min_wm
          from dwa_keys_tmp;

        pkg_dwa_test.eq(p_step || ' keys', l_keys, p_keys);
        pkg_dwa_test.eq(p_step || ' min wm', l_min_wm, p_min_wm);
        pkg_dwa_test.eq(p_step || ' wm before', wm, p_wm_before);

        pkg_dwa.prepare_batches(p_batch_size => p_batch_size, p_commit_batch => true);
        while pkg_dwa.next_batch loop
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

            pkg_dwa.finish_batch;
        end loop;

        pkg_dwa_test.eq(p_step || ' batches', to_char(l_batches), p_batches);
        pkg_dwa.finalize;
        pkg_dwa_test.eq(p_step || ' debt', debt_state, p_debt);
        pkg_dwa_test.eq(p_step || ' wm', wm, p_wm);
    end apply;
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
    apply(
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

    apply(
        'roll close', date '2024-06-02', 2,
        'a,b,c', '2',
        'a:100:2024-06-02,b:40:2024-06-02,c:7:2024-06-02',
        '2024-06-02 09:00:00', '2024-06-01 08:00:00', '2024-06-01 08:00:00'
    );

    -- Nothing changed. Open keys come back with a watermark older than the stored one.
    -- b stays on the day it closed. The watermark does not move back.
    apply(
        'roll open', date '2024-06-03', 1,
        'a,c', '2',
        'a:100:2024-06-03,b:40:2024-06-02,c:7:2024-06-03',
        '2024-06-02 09:00:00', '2024-06-02 09:00:00', '2024-06-01 08:00:00'
    );

    -- Soft delete of an open key. The tombstone is captured; the debt row goes away.
    update inc_test_roll
       set deleted_at = c_del
     where id = 'a';

    apply(
        'roll delete', date '2024-06-04', 1,
        'a,c', '2',
        'b:40:2024-06-02,c:7:2024-06-04',
        '2024-06-03 10:00:00', '2024-06-02 09:00:00', '2024-06-01 08:00:00'
    );

    -- Next day the deleted key is not resurrected. c, still open, moves forward.
    apply(
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

    apply(
        'roll restore', date '2024-06-05', 1,
        'a,c', '2',
        'a:100:2024-06-05,b:40:2024-06-02,c:7:2024-06-05',
        '2024-06-03 10:00:00', '2024-06-03 10:00:00', '2024-06-01 08:00:00'
    );

    pkg_dwa_test.pass('rolling_and_soft_delete');
end;
/
