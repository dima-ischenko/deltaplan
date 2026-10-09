-- Same engine edges as tests/postgres/deltaplan_test_edges.sql.
-- Oracle stores '' as null, so empty string is not a distinct key part here.
-- set serveroutput on size unlimited
-- exec pkg_deltaplan_test_edges.run

create or replace package pkg_deltaplan_test_edges is
    procedure run;
end pkg_deltaplan_test_edges;
/

create or replace package body pkg_deltaplan_test_edges is

    c_target constant varchar2(128) := 'inc_test_tgt';
    c_noon   constant date := timestamp '2024-06-01 12:00:00';

    procedure fail(p_test varchar2, p_detail varchar2) is
    begin
        raise_application_error(-20999, p_test || ': ' || p_detail);
    end fail;

    procedure eq(p_test varchar2, p_got varchar2, p_exp varchar2) is
    begin
        if p_got = p_exp or (p_got is null and p_exp is null) then
            return;
        end if;
        fail(p_test, 'expected [' || nvl(p_exp, 'null') || '] got [' || nvl(p_got, 'null') || ']');
    end eq;

    procedure pass(p_test varchar2) is
    begin
        commit;
        dbms_output.put_line('ok ' || p_test);
    end pass;

    procedure reset is
    begin
        delete from deltaplan_keys;
        delete from deltaplan_batch;
        delete from deltaplan_watermark
        where target_table in (c_target, 'other_tgt');
        delete from inc_test_a;
        delete from inc_test_b;
        delete from inc_test_tgt;
        pkg_deltaplan.initialize(c_target, 'all', 0);
        commit;
    end reset;

    procedure add_row(p_table varchar2, p_id varchar2, p_amount number, p_at date) is
    begin
        execute immediate
            'insert into ' || p_table || ' (id, amount, updated_at) values (:1, :2, :3)'
            using p_id, p_amount, p_at;
    end add_row;

    procedure capture_source(p_table varchar2) is
    begin
        pkg_deltaplan.capture_delta(
            p_source_table => p_table,
            p_sql =>
                'select id as pk_1, null as pk_2, null as pk_3, updated_at as watermark'
                || ' from ' || p_table
                || ' where updated_at > :since'
        );
    end capture_source;

    function key_count(p_segment varchar2 default 'all') return varchar2 is
        l_cnt number;
    begin
        select count(*)
        into l_cnt
        from (
            select distinct pk_1, pk_2, pk_3
            from deltaplan_keys
            where target_table = c_target
              and data_segment = p_segment
        );
        return to_char(l_cnt);
    end key_count;

    function wm(p_source varchar2, p_segment varchar2 default 'all') return varchar2 is
        l_value date;
    begin
        select watermark
        into l_value
        from deltaplan_watermark
        where target_table = c_target
          and data_segment = p_segment
          and source_table = p_source;
        return to_char(l_value, 'YYYY-MM-DD HH24:MI:SS');
    exception
        when no_data_found then
            return null;
    end wm;

    procedure test_initial_bound is
    begin
        reset;
        add_row('inc_test_a', 'old', 4, date '1999-12-31');
        pkg_deltaplan.initialize(c_target, 'all', 100000);
        capture_source('inc_test_a');
        eq('epoch keys', key_count(), '1');
        pkg_deltaplan.finalize;
        eq('epoch wm', wm('inc_test_a'), '1999-12-31 00:00:00');
        pass('initial_bound_includes_history');
    end test_initial_bound;

    procedure test_watermark_stays is
    begin
        reset;
        insert into deltaplan_watermark (target_table, data_segment, source_table, watermark, updated_at)
        values (c_target, 'all', 'inc_test_a', c_noon, sysdate);
        add_row('inc_test_a', 'early', 1, timestamp '2024-06-01 11:00:00');
        pkg_deltaplan.initialize(c_target, 'all', 2);
        capture_source('inc_test_a');
        eq('kept keys', key_count(), '1');
        pkg_deltaplan.finalize;
        eq('kept wm', wm('inc_test_a'), '2024-06-01 12:00:00');
        pass('watermark_does_not_move_backwards');
    end test_watermark_stays;

    procedure test_segments is
        l_cnt number;
    begin
        reset;
        add_row('inc_test_a', 's', 1, c_noon);
        pkg_deltaplan.initialize(c_target, 'east', 0);
        capture_source('inc_test_a');
        pkg_deltaplan.finalize;
        select count(*) into l_cnt
        from deltaplan_watermark
        where target_table = c_target and data_segment = 'east' and source_table = 'inc_test_a';
        eq('segment east rows', to_char(l_cnt), '1');
        eq('segment all untouched', wm('inc_test_a'), null);
        pkg_deltaplan.initialize(c_target, 'all', 0);
        capture_source('inc_test_a');
        eq('segment all keys', key_count(), '1');
        pkg_deltaplan.finalize;
        pass('segments_do_not_share_watermarks');
    end test_segments;

    procedure test_equal_timestamp is
    begin
        reset;
        add_row('inc_test_a', 'a', 1, c_noon);
        capture_source('inc_test_a');
        pkg_deltaplan.finalize;
        add_row('inc_test_a', 'b', 2, c_noon);
        pkg_deltaplan.initialize(c_target, 'all', 0);
        capture_source('inc_test_a');
        eq('equal ts hidden', key_count(), '0');
        pkg_deltaplan.initialize(c_target, 'all', 0);
        pkg_deltaplan.capture_delta(
            p_source_table => 'inc_test_a',
            p_sql =>
                'select id as pk_1, null as pk_2, null as pk_3, updated_at as watermark'
                || ' from inc_test_a where updated_at > :since',
            p_lookback_hours => 1
        );
        eq('equal ts lookback', key_count(), '2');
        pass('equal_timestamp_needs_lookback');
    end test_equal_timestamp;

    procedure test_fractional_lookback is
    begin
        reset;
        insert into deltaplan_watermark (target_table, data_segment, source_table, watermark, updated_at)
        values (c_target, 'all', 'inc_test_a', c_noon, sysdate);
        add_row('inc_test_a', 'a', 1, timestamp '2024-06-01 10:00:00');
        add_row('inc_test_a', 'b', 1, timestamp '2024-06-01 10:30:00');
        add_row('inc_test_a', 'c', 1, timestamp '2024-06-01 11:00:00');
        add_row('inc_test_a', 'd', 1, timestamp '2024-06-01 12:30:00');
        pkg_deltaplan.initialize(c_target, 'all', 1.5);
        capture_source('inc_test_a');
        eq('fractional keys', key_count(), '2');
        pass('fractional_lookback');
    end test_fractional_lookback;

    procedure test_duplicate_keys is
        l_cnt number;
    begin
        reset;
        pkg_deltaplan.capture_delta(
            p_source_table => 'inc_test_a',
            p_sql => q'[
                select s.pk_1, s.pk_2, s.pk_3, s.watermark
                from (
                    select 'p' pk_1, cast(null as varchar2(1)) pk_2, cast(null as varchar2(1)) pk_3,
                           date '2024-08-01' watermark
                    from dual
                    union all
                    select 'p', null, null, date '2024-08-02' from dual
                ) s
                where s.watermark > :since
            ]'
        );
        select count(*) into l_cnt
        from deltaplan_keys
        where target_table = c_target and data_segment = 'all';
        eq('dup raw rows', to_char(l_cnt), '2');
        eq('dup distinct', key_count(), '1');
        select count(*) into l_cnt from deltaplan_keyset;
        eq('dup keyset', to_char(l_cnt), '1');
        pkg_deltaplan.finalize;
        eq('dup wm', wm('inc_test_a'), '2024-08-02 00:00:00');
        pass('duplicate_keys_collapse');
    end test_duplicate_keys;

    procedure test_null_pk_parts is
        l_pk2 deltaplan_batch.pk_2%type;
    begin
        reset;
        pkg_deltaplan.capture_delta(
            p_source_table => 'inc_test_a',
            p_sql => q'[
                select s.pk_1, s.pk_2, s.pk_3, s.watermark
                from (
                    select 'a' pk_1, cast(null as varchar2(1)) pk_2, cast(null as varchar2(1)) pk_3,
                           date '2024-09-01' watermark
                    from dual
                    union all
                    select 'a', 'x', null, date '2024-09-01' from dual
                    union all
                    select 'a', 'y', null, date '2024-09-01' from dual
                ) s
                where s.watermark > :since
            ]'
        );
        eq('null pk keys', key_count(), '3');
        pkg_deltaplan.prepare_batches(p_batch_size => 1, p_commit => false);
        if not pkg_deltaplan.next_batch then
            fail('null pk', 'missing first batch');
        end if;
        select pk_2 into l_pk2 from deltaplan_batch;
        if l_pk2 is not null then
            fail('null pk', 'first batch pk_2 was [' || l_pk2 || ']');
        end if;
        pkg_deltaplan.finish_batch;
        if not pkg_deltaplan.next_batch then
            fail('null pk', 'missing second batch');
        end if;
        select pk_2 into l_pk2 from deltaplan_batch;
        eq('pk2 x', l_pk2, 'x');
        pkg_deltaplan.finish_batch;
        if not pkg_deltaplan.next_batch then
            fail('null pk', 'missing third batch');
        end if;
        select pk_2 into l_pk2 from deltaplan_batch;
        eq('pk2 y', l_pk2, 'y');
        pkg_deltaplan.finish_batch;
        pkg_deltaplan.finalize;
        pass('null_pk_parts_stay_distinct');
    end test_null_pk_parts;

    procedure test_keyset is
        l_cnt number;
    begin
        reset;
        add_row('inc_test_a', 'a', 1, c_noon);
        add_row('inc_test_b', 'a', 2, c_noon);
        capture_source('inc_test_a');
        capture_source('inc_test_b');
        select count(*) into l_cnt
        from deltaplan_keys
        where target_table = c_target and data_segment = 'all';
        eq('two source rows', to_char(l_cnt), '2');
        select count(*) into l_cnt
        from deltaplan_keyset
        where target_table = c_target and data_segment = 'all';
        eq('two source keyset', to_char(l_cnt), '1');
        pkg_deltaplan.finalize;
        pass('keyset_is_distinct');
    end test_keyset;

    procedure test_empty_delta is
    begin
        reset;
        add_row('inc_test_a', 'a', 1, c_noon);
        capture_source('inc_test_a');
        pkg_deltaplan.finalize;
        pkg_deltaplan.initialize(c_target, 'all', 0);
        capture_source('inc_test_a');
        eq('empty keys', key_count(), '0');
        pkg_deltaplan.finalize;
        eq('empty wm', wm('inc_test_a'), '2024-06-01 12:00:00');
        pass('empty_delta_keeps_watermark');
    end test_empty_delta;

    procedure expect_code(p_test varchar2, p_code number) is
    begin
        fail(p_test, 'expected ' || p_code);
    end expect_code;

    procedure test_guards is
    begin
        reset;
        pkg_deltaplan.finalize;
        begin
            capture_source('inc_test_a');
            expect_code('guard init', -20001);
        exception
            when others then
                if sqlcode != -20001 then
                    raise;
                end if;
        end;

        begin
            pkg_deltaplan.initialize(c_target, 'all', -1);
            expect_code('guard lookback', -20002);
        exception
            when others then
                if sqlcode != -20002 then
                    raise;
                end if;
        end;

        begin
            pkg_deltaplan.initialize(null, 'all', 0);
            expect_code('guard target', -20006);
        exception
            when others then
                if sqlcode != -20006 then
                    raise;
                end if;
        end;

        pkg_deltaplan.initialize(c_target, 'all', 0);
        begin
            pkg_deltaplan.capture_delta('inc_test_a', 'select 1 from dual');
            expect_code('guard since missing', -20015);
        exception
            when others then
                if sqlcode != -20015 then
                    raise;
                end if;
        end;

        begin
            pkg_deltaplan.capture_delta('inc_test_a', 'select 1 from dual where :since > :since');
            expect_code('guard since twice', -20015);
        exception
            when others then
                if sqlcode != -20015 then
                    raise;
                end if;
        end;

        begin
            pkg_deltaplan.prepare_batches(0);
            expect_code('guard batch 0', -20003);
        exception
            when others then
                if sqlcode != -20003 then
                    raise;
                end if;
        end;

        begin
            pkg_deltaplan.prepare_batches(1.5);
            expect_code('guard batch fraction', -20003);
        exception
            when others then
                if sqlcode != -20003 then
                    raise;
                end if;
        end;

        begin
            pkg_deltaplan.capture_delta(
                p_source_table => 'inc_test_a',
                p_sql => q'[
                    select cast(null as varchar2(1)) pk_1,
                           cast(null as varchar2(1)) pk_2,
                           cast(null as varchar2(1)) pk_3,
                           date '2024-07-01' watermark
                    from dual
                    where date '2024-07-01' > :since
                ]'
            );
            fail('null pk_1', 'insert was accepted');
        exception
            when others then
                if sqlcode not in (-1400, -1407) then
                    raise;
                end if;
        end;
        pass('capture_guards');
    end test_guards;

    procedure run is
    begin
        dbms_output.enable(buffer_size => null);
        test_initial_bound;
        test_watermark_stays;
        test_segments;
        test_equal_timestamp;
        test_fractional_lookback;
        test_duplicate_keys;
        test_null_pk_parts;
        test_keyset;
        test_empty_delta;
        test_guards;
        dbms_output.put_line('pkg_deltaplan_test_edges: passed');
    exception
        when others then
            rollback;
            raise;
    end run;

end pkg_deltaplan_test_edges;
/
