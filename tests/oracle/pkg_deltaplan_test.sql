-- Checks for pkg_deltaplan.
-- Requires deltaplan_watermark, deltaplan_keys, deltaplan_batch and the package itself.
-- set serveroutput on size unlimited
-- @pkg_deltaplan_test.sql
-- exec pkg_deltaplan_test.run

create or replace package pkg_deltaplan_test is

    procedure run;

end pkg_deltaplan_test;
/

create or replace package body pkg_deltaplan_test is

    c_target constant varchar2(128) := 'inc_test_tgt';
    c_t1     constant date := timestamp '2024-01-15 10:00:00';
    c_t2     constant date := timestamp '2024-02-01 00:00:00';
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

        fail(
            p_test,
            'expected [' || nvl(p_exp, 'null') || '] got [' || nvl(p_got, 'null') || ']'
        );
    end eq;

    procedure pass(p_test varchar2) is
    begin
        commit;
        dbms_output.put_line('ok ' || p_test);
    end pass;

    -- The fixture tables are created by run.sql. A package runs without roles,
    -- so it cannot rely on CREATE TABLE granted only through RESOURCE.
    procedure setup is
    begin
        delete from inc_test_seen;
        delete from inc_test_expect;
        delete from inc_test_tgt;
        delete from inc_test_b;
        delete from inc_test_a;
    end setup;

    procedure reset is
    begin
        delete from deltaplan_keys;
        delete from deltaplan_batch;
        delete from deltaplan_watermark
        where target_table in (c_target, 'other_tgt');

        delete from inc_test_a;
        delete from inc_test_b;
        delete from inc_test_tgt;
        delete from inc_test_expect;
        delete from inc_test_seen;

        pkg_deltaplan.initialize(c_target, 'all', 0);
        commit;
    end reset;

    procedure add_row(
        p_table  varchar2,
        p_id     varchar2,
        p_amount number,
        p_at     date
    ) is
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
                'select id as pk_1,'
                || ' null as pk_2,'
                || ' null as pk_3,'
                || ' updated_at as watermark'
                || ' from ' || p_table
                || ' where updated_at > :since'
        );
    end capture_source;

    procedure capture_both is
    begin
        capture_source('inc_test_a');
        capture_source('inc_test_b');
    end capture_both;

    procedure merge_all is
    begin
        merge into inc_test_tgt t
        using (
            select k.pk_1 as id,
                   nvl(max(a.amount), 0) + nvl(max(b.amount), 0) as amount
            from deltaplan_keys k
            left join inc_test_a a on a.id = k.pk_1
            left join inc_test_b b on b.id = k.pk_1
            where k.target_table = pkg_deltaplan.get_target_table
              and k.data_segment = pkg_deltaplan.get_data_segment
            group by k.pk_1
        ) s
        on (t.id = s.id)
        when matched then update
            set t.amount = s.amount,
                t.touch = t.touch + 1
        when not matched then insert (id, amount, touch)
            values (s.id, s.amount, 1);
    end merge_all;

    procedure merge_batch is
    begin
        merge into inc_test_tgt t
        using (
            select k.pk_1 as id,
                   nvl(max(a.amount), 0) + nvl(max(b.amount), 0) as amount
            from deltaplan_batch k
            left join inc_test_a a on a.id = k.pk_1
            left join inc_test_b b on b.id = k.pk_1
            group by k.pk_1
        ) s
        on (t.id = s.id)
        when matched then update
            set t.amount = s.amount,
                t.touch = t.touch + 1
        when not matched then insert (id, amount, touch)
            values (s.id, s.amount, 1);
    end merge_batch;

    function key_count return varchar2 is
        l_cnt number;
    begin
        select count(*)
        into l_cnt
        from (
            select distinct pk_1, pk_2, pk_3
            from deltaplan_keys
            where target_table = c_target
              and data_segment = 'all'
        );

        return to_char(l_cnt);
    end key_count;

    function wm(p_source varchar2) return varchar2 is
        l_value date;
    begin
        select watermark
        into l_value
        from deltaplan_watermark
        where target_table = c_target
          and data_segment = 'all'
          and source_table = p_source;

        return to_char(l_value, 'YYYY-MM-DD HH24:MI:SS');
    exception
        when no_data_found then
            return null;
    end wm;

    function tgt_state return varchar2 is
        l_value varchar2(4000);
    begin
        select listagg(id || ':' || amount || ':' || touch, ',')
               within group (order by id)
        into l_value
        from inc_test_tgt;

        return l_value;
    end tgt_state;

    function ids_in_batch return varchar2 is
        l_ids varchar2(4000);
    begin
        select listagg(pk_1, ',') within group (order by pk_1)
        into l_ids
        from deltaplan_batch;

        return l_ids;
    end ids_in_batch;

    function seen(p_batch number) return varchar2 is
        l_ids varchar2(4000);
    begin
        select listagg(id, ',') within group (order by id)
        into l_ids
        from inc_test_seen
        where batch_no = p_batch;

        return l_ids;
    end seen;

    function tracking_count(p_target varchar2) return varchar2 is
        l_cnt number;
    begin
        select count(*)
        into l_cnt
        from deltaplan_watermark
        where target_table = p_target;

        return to_char(l_cnt);
    end tracking_count;

    procedure expect_error(p_test varchar2, p_code number) is
    begin
        fail(p_test, 'expected ' || p_code);
    end expect_error;

    procedure test_static_without_batches is
    begin
        reset;
        add_row('inc_test_a', '1', 10, c_t1);
        add_row('inc_test_a', '2', 20, c_t1);
        add_row('inc_test_b', '2', 5, c_t1);
        add_row('inc_test_b', '3', 7, c_t1);
        capture_both;

        insert into deltaplan_keys (
            target_table, data_segment, source_table,
            pk_1, pk_2, pk_3, watermark
        ) values (
            'other_tgt', 'all', 'inc_test_a',
            'z', null, null, c_t2
        );

        eq('static keys', key_count, '3');
        eq('static batch no', to_char(pkg_deltaplan.get_batch_no), to_char(null));
        merge_all;
        eq('static tgt', tgt_state, '1:10:1,2:25:1,3:7:1');

        pkg_deltaplan.finalize;
        eq('static wm a', wm('inc_test_a'), '2024-01-15 10:00:00');
        eq('static wm b', wm('inc_test_b'), '2024-01-15 10:00:00');
        eq('static other tracking', tracking_count('other_tgt'), '0');
        eq('static closed', pkg_deltaplan.get_target_table, to_char(null));

        pkg_deltaplan.initialize(c_target, 'all', 0);
        capture_both;
        eq('static second keys', key_count, '0');
        merge_all;
        pkg_deltaplan.finalize;
        eq('static second wm a', wm('inc_test_a'), '2024-01-15 10:00:00');
        eq('static second tgt', tgt_state, '1:10:1,2:25:1,3:7:1');

        update inc_test_a
        set amount = 50,
            updated_at = c_t2
        where id = '2';

        pkg_deltaplan.initialize(c_target, 'all', 0);
        capture_both;
        eq('static delta keys', key_count, '1');
        merge_all;
        pkg_deltaplan.finalize;
        eq('static delta tgt', tgt_state, '1:10:1,2:55:2,3:7:1');
        eq('static delta wm a', wm('inc_test_a'), '2024-02-01 00:00:00');
        eq('static delta wm b', wm('inc_test_b'), '2024-01-15 10:00:00');

        delete from deltaplan_keys where target_table = 'other_tgt';
        pass('static_without_batches');
    end test_static_without_batches;

    procedure test_lookback_window is
    begin
        reset;

        insert into deltaplan_watermark (
            target_table, data_segment, source_table, watermark, updated_at
        ) values (
            c_target, 'all', 'inc_test_a', c_noon, sysdate
        );

        add_row('inc_test_a', 'a', 1, timestamp '2024-06-01 09:00:00');
        add_row('inc_test_a', 'd', 1, timestamp '2024-06-01 10:00:00');
        add_row('inc_test_a', 'b', 1, timestamp '2024-06-01 11:00:00');
        add_row('inc_test_a', 'c', 1, timestamp '2024-06-01 13:00:00');

        pkg_deltaplan.initialize(c_target, 'all', 2);
        capture_source('inc_test_a');
        eq('lookback keys', key_count, '2');
        merge_all;
        eq('lookback tgt', tgt_state, 'b:1:1,c:1:1');
        pkg_deltaplan.finalize;
        eq('lookback wm', wm('inc_test_a'), '2024-06-01 13:00:00');
        pass('lookback_window');
    end test_lookback_window;

    procedure test_static_batches is
        l_step number := 0;
        l_no   number;
    begin
        reset;
        add_row('inc_test_a', 'a', 1, c_t1);
        add_row('inc_test_a', 'b', 2, c_t1);
        add_row('inc_test_a', 'c', 3, c_t1);
        add_row('inc_test_a', 'd', 4, c_t1);
        add_row('inc_test_a', 'e', 5, c_t1);
        capture_source('inc_test_a');

        pkg_deltaplan.prepare_batches(p_batch_size => 2);

        while pkg_deltaplan.next_batch loop
            l_step := l_step + 1;
            l_no := pkg_deltaplan.get_batch_no;

            insert into inc_test_seen (batch_no, id)
            select l_no, pk_1
            from deltaplan_batch;

            merge_batch;

            if l_step = 1 then
                eq('open batch', to_char(l_no), '1');
                eq('open keys', ids_in_batch, 'a,b');
                eq('open tgt', tgt_state, 'a:1:1,b:2:1');
                eq('open wm', wm('inc_test_a'), to_char(null));
            end if;

            pkg_deltaplan.finish_batch;
        end loop;

        eq('batches', to_char(l_step), '3');
        eq('seen 1', seen(1), 'a,b');
        eq('seen 2', seen(2), 'c,d');
        eq('seen 3', seen(3), 'e');
        eq('batch tgt before finalize', tgt_state, 'a:1:1,b:2:1,c:3:1,d:4:1,e:5:1');
        eq('batch wm before finalize', wm('inc_test_a'), to_char(null));

        pkg_deltaplan.finalize;
        eq('batch wm', wm('inc_test_a'), '2024-01-15 10:00:00');
        pass('static_batches');
    end test_static_batches;

    procedure test_same_result is
        l_wm_a varchar2(19);
        l_wm_b varchar2(19);
        l_diff number;
    begin
        reset;
        add_row('inc_test_a', 'a', 10, c_t1);
        add_row('inc_test_a', 'b', 20, c_t1);
        add_row('inc_test_b', 'b', 3, c_t1);
        add_row('inc_test_b', 'c', 4, c_t1);
        capture_both;
        merge_all;
        pkg_deltaplan.finalize;

        l_wm_a := wm('inc_test_a');
        l_wm_b := wm('inc_test_b');
        delete from inc_test_expect;
        insert into inc_test_expect (id, amount, touch)
        select id, amount, touch
        from inc_test_tgt;

        delete from inc_test_tgt;
        delete from deltaplan_watermark
        where target_table = c_target;
        commit;

        pkg_deltaplan.initialize(c_target, 'all', 0);
        capture_both;
        pkg_deltaplan.prepare_batches(p_batch_size => 1);

        while pkg_deltaplan.next_batch loop
            merge_batch;
            pkg_deltaplan.finish_batch;
        end loop;

        pkg_deltaplan.finalize;

        select count(*)
        into l_diff
        from (
            select id, amount, touch from inc_test_tgt
            minus
            select id, amount, touch from inc_test_expect
            union all
            select id, amount, touch from inc_test_expect
            minus
            select id, amount, touch from inc_test_tgt
        );

        eq('same rows', to_char(l_diff), '0');
        eq('same wm a', wm('inc_test_a'), l_wm_a);
        eq('same wm b', wm('inc_test_b'), l_wm_b);
        pass('same_result');
    end test_same_result;

    procedure test_resume_same_batch is
        l_no  number;
        l_ids varchar2(10);
    begin
        reset;
        add_row('inc_test_a', 'a', 1, c_t1);
        add_row('inc_test_a', 'b', 2, c_t1);
        add_row('inc_test_a', 'c', 3, c_t1);
        capture_source('inc_test_a');
        pkg_deltaplan.prepare_batches(p_batch_size => 2);

        if not pkg_deltaplan.next_batch then
            fail('resume', 'missing first batch');
        end if;

        merge_batch;
        pkg_deltaplan.finish_batch;
        eq('resume after first', tgt_state, 'a:1:1,b:2:1');

        if not pkg_deltaplan.next_batch then
            fail('resume', 'missing second batch');
        end if;

        l_no := pkg_deltaplan.get_batch_no;
        l_ids := ids_in_batch;
        merge_batch;
        rollback;

        eq('resume rolled back', tgt_state, 'a:1:1,b:2:1');

        if not pkg_deltaplan.next_batch then
            fail('resume', 'batch was not reopened');
        end if;

        eq('resume batch no', to_char(pkg_deltaplan.get_batch_no), to_char(l_no));
        eq('resume keys', ids_in_batch, l_ids);
        merge_batch;
        pkg_deltaplan.finish_batch;

        if pkg_deltaplan.next_batch then
            fail('resume', 'unexpected extra batch');
        end if;

        eq('resume wm still old', wm('inc_test_a'), to_char(null));
        pkg_deltaplan.finalize;
        eq('resume tgt', tgt_state, 'a:1:1,b:2:1,c:3:1');
        eq('resume wm', wm('inc_test_a'), '2024-01-15 10:00:00');
        pass('resume_same_batch');
    end test_resume_same_batch;

    procedure test_batch_guards is
    begin
        reset;
        add_row('inc_test_a', 'a', 1, c_t1);
        add_row('inc_test_a', 'b', 1, c_t1);
        add_row('inc_test_a', 'c', 1, c_t1);
        capture_source('inc_test_a');
        pkg_deltaplan.prepare_batches(p_batch_size => 2);

        if not pkg_deltaplan.next_batch then
            fail('guard finalize', 'missing batch');
        end if;

        begin
            pkg_deltaplan.finalize;
            expect_error('guard finalize', -20005);
        exception
            when others then
                if sqlcode != -20005 then
                    raise;
                end if;
        end;

        merge_batch;
        pkg_deltaplan.finish_batch;

        while pkg_deltaplan.next_batch loop
            merge_batch;
            pkg_deltaplan.finish_batch;
        end loop;

        pkg_deltaplan.finalize;
        eq('guard tgt', tgt_state, 'a:1:1,b:1:1,c:1:1');

        reset;
        add_row('inc_test_a', 'a', 1, c_t1);
        add_row('inc_test_a', 'b', 1, c_t1);
        capture_source('inc_test_a');
        pkg_deltaplan.prepare_batches(p_batch_size => 1);

        if not pkg_deltaplan.next_batch then
            fail('guard next', 'missing batch');
        end if;

        begin
            if pkg_deltaplan.next_batch then
                null;
            end if;
            expect_error('guard next', -20014);
        exception
            when others then
                if sqlcode != -20014 then
                    raise;
                end if;
        end;

        merge_batch;
        pkg_deltaplan.finish_batch;

        while pkg_deltaplan.next_batch loop
            merge_batch;
            pkg_deltaplan.finish_batch;
        end loop;

        pkg_deltaplan.finalize;

        reset;
        add_row('inc_test_a', 'a', 1, c_t1);
        capture_source('inc_test_a');
        pkg_deltaplan.prepare_batches(p_batch_size => 2);

        begin
            pkg_deltaplan.prepare_batches(p_batch_size => 3);
            expect_error('guard size', -20009);
        exception
            when others then
                if sqlcode != -20009 then
                    raise;
                end if;
        end;

        begin
            pkg_deltaplan.prepare_batches(p_batch_size => 2, p_commit => false);
            expect_error('guard commit', -20018);
        exception
            when others then
                if sqlcode != -20018 then
                    raise;
                end if;
        end;

        begin
            capture_source('inc_test_a');
            expect_error('guard capture', -20013);
        exception
            when others then
                if sqlcode != -20013 then
                    raise;
                end if;
        end;

        while pkg_deltaplan.next_batch loop
            merge_batch;
            pkg_deltaplan.finish_batch;
        end loop;

        pkg_deltaplan.finalize;

        reset;

        begin
            if pkg_deltaplan.next_batch then
                null;
            end if;
            expect_error('guard no prepare', -20016);
        exception
            when others then
                if sqlcode != -20016 then
                    raise;
                end if;
        end;

        begin
            pkg_deltaplan.finish_batch;
            expect_error('guard no batch', -20017);
        exception
            when others then
                if sqlcode != -20017 then
                    raise;
                end if;
        end;

        pass('batch_guards');
    end test_batch_guards;

    procedure test_one_pk_one_batch is
        l_rows number;
        l_temp number;
    begin
        reset;
        add_row('inc_test_a', 'a', 10, c_t1);
        add_row('inc_test_a', 'b', 20, c_t1);
        add_row('inc_test_b', 'a', 1, c_t1);
        add_row('inc_test_b', 'b', 2, c_t1);
        capture_both;
        pkg_deltaplan.prepare_batches(p_batch_size => 10);

        if not pkg_deltaplan.next_batch then
            fail('one pk', 'missing batch');
        end if;

        select count(*) into l_rows from deltaplan_batch;
        select count(*)
        into l_temp
        from deltaplan_keys
        where target_table = c_target
          and data_segment = 'all';

        eq('one pk keys', ids_in_batch, 'a,b');
        eq('one pk batch rows', to_char(l_rows), '2');
        eq('one pk temp rows', to_char(l_temp), '4');
        merge_batch;
        pkg_deltaplan.finish_batch;

        if pkg_deltaplan.next_batch then
            fail('one pk', 'second batch');
        end if;

        pkg_deltaplan.finalize;
        eq('one pk tgt', tgt_state, 'a:11:1,b:22:1');
        pass('one_pk_one_batch');
    end test_one_pk_one_batch;

    procedure test_rollback_without_commit is
    begin
        reset;
        add_row('inc_test_a', 'a', 1, c_t1);
        add_row('inc_test_a', 'b', 2, c_t1);
        capture_source('inc_test_a');
        pkg_deltaplan.prepare_batches(p_batch_size => 1, p_commit => false);

        while pkg_deltaplan.next_batch loop
            merge_batch;
            pkg_deltaplan.finish_batch;
        end loop;

        rollback;
        eq('rollback tgt', tgt_state, to_char(null));
        pkg_deltaplan.finalize;
        eq('rollback wm', wm('inc_test_a'), to_char(null));
        pass('rollback_without_commit');
    end test_rollback_without_commit;

    procedure run is
    begin
        dbms_output.enable(buffer_size => null);
        setup;
        test_static_without_batches;
        test_lookback_window;
        test_static_batches;
        test_same_result;
        test_resume_same_batch;
        test_batch_guards;
        test_one_pk_one_batch;
        test_rollback_without_commit;
        dbms_output.put_line('pkg_deltaplan_test: passed');
    exception
        when others then
            rollback;
            raise;
    end run;

end pkg_deltaplan_test;
/
