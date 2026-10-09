-- utPLSQL suite for pkg_deltaplan.
-- Requires deltaplan_watermark, deltaplan_keys_tmp, deltaplan_batch_tmp
-- and utPLSQL (schema UT3, public synonyms).
--
-- set serveroutput on size unlimited
-- @pkg_deltaplan_test.sql
-- exec ut.run('pkg_deltaplan_test')

create or replace package pkg_deltaplan_test is

    --%suite(deltaplan)
    --%suitepath(deltaplan)

    --%beforeeach
    procedure reset_session;

    --%test(static load without batches)
    procedure static_without_batches;

    --%test(lookback window)
    procedure lookback_window;

    --%test(static load in batches)
    procedure static_batches;

    --%test(batched load matches static merge)
    procedure same_result;

    --%test(resume the same batch after rollback)
    procedure resume_same_batch;

    --%test(batch API guards)
    procedure batch_guards;

    --%test(one primary key from two sources shares a batch)
    procedure one_pk_one_batch;

    --%test(rollback without commit leaves the watermark)
    procedure rollback_without_commit;

end pkg_deltaplan_test;
/

create or replace package body pkg_deltaplan_test is

    c_target constant varchar2(128) := 'inc_test_tgt';
    c_t1     constant date := timestamp '2024-01-15 10:00:00';
    c_t2     constant date := timestamp '2024-02-01 00:00:00';
    c_noon   constant date := timestamp '2024-06-01 12:00:00';
    -- Volume of a source table in the data-path checks. Guard tests stay small.
    c_n      constant pls_integer := 10000;
    c_b_from constant pls_integer := 5001;
    c_b_to   constant pls_integer := 15000;
    c_batch  constant pls_integer := 4000;

    procedure reset_session is
    begin
        delete from deltaplan_keys_tmp;
        delete from deltaplan_batch_tmp;
        delete from deltaplan_watermark
        where target_table in (c_target, 'other_tgt');

        delete from inc_test_a;
        delete from inc_test_b;
        delete from inc_test_tgt;
        delete from inc_test_expect;
        delete from inc_test_seen;

        pkg_deltaplan.initialize(c_target, 'all', 0);
        commit;
    end reset_session;

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

    function pk(p_n number) return varchar2 is
    begin
        return lpad(to_char(p_n), 5, '0');
    end pk;

    procedure load_a(p_from number, p_to number, p_at date, p_amount number default null) is
    begin
        insert into inc_test_a (id, amount, updated_at)
        select lpad(to_char(p_from + level - 1), 5, '0'),
               nvl(p_amount, p_from + level - 1),
               p_at
        from dual
        connect by level <= (p_to - p_from + 1);
    end load_a;

    procedure load_b(p_from number, p_to number, p_at date) is
    begin
        insert into inc_test_b (id, amount, updated_at)
        select lpad(to_char(p_from + level - 1), 5, '0'),
               1,
               p_at
        from dual
        connect by level <= (p_to - p_from + 1);
    end load_b;

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
            from deltaplan_keys_tmp k
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
            from deltaplan_batch_tmp k
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

    function key_count return number is
        l_cnt number;
    begin
        select count(*)
        into l_cnt
        from (
            select distinct pk_1, pk_2, pk_3
            from deltaplan_keys_tmp
            where target_table = c_target
              and data_segment = 'all'
        );

        return l_cnt;
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

    function tgt_count return number is
        l_cnt number;
    begin
        select count(*) into l_cnt from inc_test_tgt;
        return l_cnt;
    end tgt_count;

    function tgt_sum_amount return number is
        l_sum number;
    begin
        select nvl(sum(amount), 0) into l_sum from inc_test_tgt;
        return l_sum;
    end tgt_sum_amount;

    function tgt_cell(p_id varchar2) return varchar2 is
        l_value varchar2(64);
    begin
        select to_char(amount, 'TM9') || ':' || to_char(touch, 'TM9')
        into l_value
        from inc_test_tgt
        where id = p_id;

        return l_value;
    exception
        when no_data_found then
            return null;
    end tgt_cell;

    function batch_count return number is
        l_cnt number;
    begin
        select count(*) into l_cnt from deltaplan_batch_tmp;
        return l_cnt;
    end batch_count;

    function batch_lo return varchar2 is
        l_id varchar2(10);
    begin
        select min(pk_1) into l_id from deltaplan_batch_tmp;
        return l_id;
    end batch_lo;

    function batch_hi return varchar2 is
        l_id varchar2(10);
    begin
        select max(pk_1) into l_id from deltaplan_batch_tmp;
        return l_id;
    end batch_hi;

    function tracking_count(p_target varchar2) return number is
        l_cnt number;
    begin
        select count(*)
        into l_cnt
        from deltaplan_watermark
        where target_table = p_target;

        return l_cnt;
    end tracking_count;

    procedure expect_code(p_name varchar2, p_code number) is
    begin
        ut.expect(sqlcode, p_name).to_equal(p_code);
    end expect_code;

    procedure static_without_batches is
        -- A: 1..10000 amount=id. B: 5001..15000 amount=1. Distinct keys=15000.
        -- sum(amount) = sum(1..10000) + 10000 = 50015000.
        l_sum number := c_n * (c_n + 1) / 2 + c_n;
        l_id  varchar2(10) := pk(c_b_from);
    begin
        load_a(1, c_n, c_t1);
        load_b(c_b_from, c_b_to, c_t1);
        capture_both;

        insert into deltaplan_keys_tmp (
            target_table, data_segment, source_table,
            pk_1, pk_2, pk_3, watermark
        ) values (
            'other_tgt', 'all', 'inc_test_a',
            'z', null, null, c_t2
        );

        ut.expect(key_count(), 'static keys').to_equal(c_b_to);
        ut.expect(pkg_deltaplan.get_batch_no, 'static batch no').to_be_null();
        merge_all;
        ut.expect(tgt_count(), 'static tgt count').to_equal(c_b_to);
        ut.expect(tgt_sum_amount(), 'static tgt sum').to_equal(l_sum);
        ut.expect(tgt_cell(pk(1)), 'static lo').to_equal('1:1');
        ut.expect(tgt_cell(pk(c_b_from)), 'static overlap')
            .to_equal(to_char(c_b_from + 1, 'TM9') || ':1');
        ut.expect(tgt_cell(pk(c_b_to)), 'static hi').to_equal('1:1');

        pkg_deltaplan.finalize;
        ut.expect(wm('inc_test_a'), 'static wm a').to_equal('2024-01-15 10:00:00');
        ut.expect(wm('inc_test_b'), 'static wm b').to_equal('2024-01-15 10:00:00');
        ut.expect(tracking_count('other_tgt'), 'static other tracking').to_equal(0);
        ut.expect(pkg_deltaplan.get_target_table, 'static closed').to_be_null();

        pkg_deltaplan.initialize(c_target, 'all', 0);
        capture_both;
        ut.expect(key_count(), 'static second keys').to_equal(0);
        merge_all;
        pkg_deltaplan.finalize;
        ut.expect(wm('inc_test_a'), 'static second wm a').to_equal('2024-01-15 10:00:00');
        ut.expect(tgt_count(), 'static second tgt count').to_equal(c_b_to);
        ut.expect(tgt_cell(pk(c_b_from)), 'static second overlap')
            .to_equal(to_char(c_b_from + 1, 'TM9') || ':1');

        update inc_test_a
        set amount = 50,
            updated_at = c_t2
        where id = l_id;

        pkg_deltaplan.initialize(c_target, 'all', 0);
        capture_both;
        ut.expect(key_count(), 'static delta keys').to_equal(1);
        merge_all;
        pkg_deltaplan.finalize;
        ut.expect(tgt_count(), 'static delta tgt count').to_equal(c_b_to);
        ut.expect(tgt_cell(pk(c_b_from)), 'static delta overlap').to_equal('51:2');
        ut.expect(tgt_cell(pk(1)), 'static delta lo').to_equal('1:1');
        ut.expect(wm('inc_test_a'), 'static delta wm a').to_equal('2024-02-01 00:00:00');
        ut.expect(wm('inc_test_b'), 'static delta wm b').to_equal('2024-01-15 10:00:00');

        delete from deltaplan_keys_tmp where target_table = 'other_tgt';
    end static_without_batches;

    procedure lookback_window is
        -- Watermark 12:00 minus 2 hours. 1..4000 at 09:00, 4001..6000 at 10:00
        -- stay out. 6001..9000 at 11:00 and 9001..10000 at 13:00 are captured.
    begin
        insert into deltaplan_watermark (
            target_table, data_segment, source_table, watermark, updated_at
        ) values (
            c_target, 'all', 'inc_test_a', c_noon, sysdate
        );

        load_a(1, 4000, timestamp '2024-06-01 09:00:00', 1);
        load_a(4001, 6000, timestamp '2024-06-01 10:00:00', 1);
        load_a(6001, 9000, timestamp '2024-06-01 11:00:00', 1);
        load_a(9001, c_n, timestamp '2024-06-01 13:00:00', 1);

        pkg_deltaplan.initialize(c_target, 'all', 2);
        capture_source('inc_test_a');
        ut.expect(key_count(), 'lookback keys').to_equal(4000);
        merge_all;
        ut.expect(tgt_count(), 'lookback tgt count').to_equal(4000);
        ut.expect(tgt_cell(pk(6001)), 'lookback in').to_equal('1:1');
        ut.expect(tgt_cell(pk(c_n)), 'lookback hi').to_equal('1:1');
        ut.expect(tgt_cell(pk(6000)), 'lookback excluded').to_be_null();
        pkg_deltaplan.finalize;
        ut.expect(wm('inc_test_a'), 'lookback wm').to_equal('2024-06-01 13:00:00');
    end lookback_window;

    procedure static_batches is
        l_step number := 0;
        l_no   number;
        l_seen number;
    begin
        load_a(1, c_n, c_t1);
        capture_source('inc_test_a');

        pkg_deltaplan.prepare_batches(p_batch_size => c_batch);

        while pkg_deltaplan.next_batch loop
            l_step := l_step + 1;
            l_no := pkg_deltaplan.get_batch_no;

            insert into inc_test_seen (batch_no, id)
            select l_no, pk_1
            from deltaplan_batch_tmp;

            merge_batch;

            if l_step = 1 then
                ut.expect(l_no, 'open batch').to_equal(1);
                ut.expect(batch_count(), 'open keys').to_equal(c_batch);
                ut.expect(batch_lo(), 'open lo').to_equal(pk(1));
                ut.expect(batch_hi(), 'open hi').to_equal(pk(c_batch));
                ut.expect(tgt_count(), 'open tgt count').to_equal(c_batch);
                ut.expect(wm('inc_test_a'), 'open wm').to_be_null();
            end if;

            pkg_deltaplan.finish_batch;
        end loop;

        ut.expect(l_step, 'batches').to_equal(3);
        select count(*) into l_seen from inc_test_seen where batch_no = 1;
        ut.expect(l_seen, 'seen 1').to_equal(c_batch);
        select count(*) into l_seen from inc_test_seen where batch_no = 2;
        ut.expect(l_seen, 'seen 2').to_equal(c_batch);
        select count(*) into l_seen from inc_test_seen where batch_no = 3;
        ut.expect(l_seen, 'seen 3').to_equal(c_n - 2 * c_batch);
        ut.expect(tgt_count(), 'batch tgt before finalize').to_equal(c_n);
        ut.expect(tgt_cell(pk(1)), 'batch lo').to_equal('1:1');
        ut.expect(tgt_cell(pk(c_n)), 'batch hi').to_equal(to_char(c_n, 'TM9') || ':1');
        ut.expect(wm('inc_test_a'), 'batch wm before finalize').to_be_null();

        pkg_deltaplan.finalize;
        ut.expect(wm('inc_test_a'), 'batch wm').to_equal('2024-01-15 10:00:00');
    end static_batches;

    procedure same_result is
        l_wm_a varchar2(19);
        l_wm_b varchar2(19);
        l_diff number;
    begin
        load_a(1, c_n, c_t1);
        load_b(c_b_from, c_b_to, c_t1);
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
        pkg_deltaplan.prepare_batches(p_batch_size => c_batch);

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

        ut.expect(l_diff, 'same rows').to_equal(0);
        ut.expect(wm('inc_test_a'), 'same wm a').to_equal(l_wm_a);
        ut.expect(wm('inc_test_b'), 'same wm b').to_equal(l_wm_b);
    end same_result;

    procedure resume_same_batch is
        l_no  number;
        l_cnt number;
        l_lo  varchar2(10);
        l_hi  varchar2(10);
    begin
        load_a(1, c_n, c_t1);
        capture_source('inc_test_a');
        pkg_deltaplan.prepare_batches(p_batch_size => c_batch);

        ut.expect(pkg_deltaplan.next_batch, 'resume first batch').to_be_true();
        merge_batch;
        pkg_deltaplan.finish_batch;
        ut.expect(tgt_count(), 'resume after first').to_equal(c_batch);

        ut.expect(pkg_deltaplan.next_batch, 'resume second batch').to_be_true();
        l_no := pkg_deltaplan.get_batch_no;
        l_cnt := batch_count;
        l_lo := batch_lo;
        l_hi := batch_hi;
        merge_batch;
        rollback;

        ut.expect(tgt_count(), 'resume rolled back').to_equal(c_batch);

        ut.expect(pkg_deltaplan.next_batch, 'resume reopened').to_be_true();
        ut.expect(pkg_deltaplan.get_batch_no, 'resume batch no').to_equal(l_no);
        ut.expect(batch_count(), 'resume keys').to_equal(l_cnt);
        ut.expect(batch_lo(), 'resume lo').to_equal(l_lo);
        ut.expect(batch_hi(), 'resume hi').to_equal(l_hi);
        merge_batch;
        pkg_deltaplan.finish_batch;

        ut.expect(pkg_deltaplan.next_batch, 'resume third batch').to_be_true();
        merge_batch;
        pkg_deltaplan.finish_batch;

        ut.expect(pkg_deltaplan.next_batch, 'resume extra batch').to_be_false();

        ut.expect(wm('inc_test_a'), 'resume wm still old').to_be_null();
        pkg_deltaplan.finalize;
        ut.expect(tgt_count(), 'resume tgt').to_equal(c_n);
        ut.expect(tgt_cell(pk(1)), 'resume lo cell').to_equal('1:1');
        ut.expect(tgt_cell(pk(c_n)), 'resume hi cell').to_equal(to_char(c_n, 'TM9') || ':1');
        ut.expect(wm('inc_test_a'), 'resume wm').to_equal('2024-01-15 10:00:00');
    end resume_same_batch;

    procedure batch_guards is
    begin
        add_row('inc_test_a', 'a', 1, c_t1);
        add_row('inc_test_a', 'b', 1, c_t1);
        add_row('inc_test_a', 'c', 1, c_t1);
        capture_source('inc_test_a');
        pkg_deltaplan.prepare_batches(p_batch_size => 2);

        ut.expect(pkg_deltaplan.next_batch, 'guard finalize batch').to_be_true();

        begin
            pkg_deltaplan.finalize;
            ut.expect(false, 'guard finalize should raise').to_be_true();
        exception
            when others then
                expect_code('guard finalize', -20005);
        end;

        merge_batch;
        pkg_deltaplan.finish_batch;

        while pkg_deltaplan.next_batch loop
            merge_batch;
            pkg_deltaplan.finish_batch;
        end loop;

        pkg_deltaplan.finalize;
        ut.expect(tgt_state(), 'guard tgt').to_equal('a:1:1,b:1:1,c:1:1');

        reset_session;
        add_row('inc_test_a', 'a', 1, c_t1);
        add_row('inc_test_a', 'b', 1, c_t1);
        capture_source('inc_test_a');
        pkg_deltaplan.prepare_batches(p_batch_size => 1);

        ut.expect(pkg_deltaplan.next_batch, 'guard next batch').to_be_true();

        begin
            if pkg_deltaplan.next_batch then
                null;
            end if;
            ut.expect(false, 'guard next should raise').to_be_true();
        exception
            when others then
                expect_code('guard next', -20014);
        end;

        merge_batch;
        pkg_deltaplan.finish_batch;

        while pkg_deltaplan.next_batch loop
            merge_batch;
            pkg_deltaplan.finish_batch;
        end loop;

        pkg_deltaplan.finalize;

        reset_session;
        add_row('inc_test_a', 'a', 1, c_t1);
        capture_source('inc_test_a');
        pkg_deltaplan.prepare_batches(p_batch_size => 2);

        begin
            pkg_deltaplan.prepare_batches(p_batch_size => 3);
            ut.expect(false, 'guard size should raise').to_be_true();
        exception
            when others then
                expect_code('guard size', -20009);
        end;

        begin
            pkg_deltaplan.prepare_batches(p_batch_size => 2, p_commit => false);
            ut.expect(false, 'guard commit should raise').to_be_true();
        exception
            when others then
                expect_code('guard commit', -20018);
        end;

        begin
            capture_source('inc_test_a');
            ut.expect(false, 'guard capture should raise').to_be_true();
        exception
            when others then
                expect_code('guard capture', -20013);
        end;

        while pkg_deltaplan.next_batch loop
            merge_batch;
            pkg_deltaplan.finish_batch;
        end loop;

        pkg_deltaplan.finalize;

        reset_session;

        begin
            if pkg_deltaplan.next_batch then
                null;
            end if;
            ut.expect(false, 'guard no prepare should raise').to_be_true();
        exception
            when others then
                expect_code('guard no prepare', -20016);
        end;

        begin
            pkg_deltaplan.finish_batch;
            ut.expect(false, 'guard no batch should raise').to_be_true();
        exception
            when others then
                expect_code('guard no batch', -20017);
        end;
    end batch_guards;

    procedure one_pk_one_batch is
        l_rows number;
        l_temp number;
    begin
        load_a(1, c_n, c_t1);
        load_b(1, c_n, c_t1);
        capture_both;
        pkg_deltaplan.prepare_batches(p_batch_size => c_n);

        ut.expect(pkg_deltaplan.next_batch, 'one pk batch').to_be_true();

        select count(*) into l_rows from deltaplan_batch_tmp;
        select count(*)
        into l_temp
        from deltaplan_keys_tmp
        where target_table = c_target
          and data_segment = 'all';

        ut.expect(batch_count(), 'one pk keys').to_equal(c_n);
        ut.expect(batch_lo(), 'one pk lo').to_equal(pk(1));
        ut.expect(batch_hi(), 'one pk hi').to_equal(pk(c_n));
        ut.expect(l_rows, 'one pk batch rows').to_equal(c_n);
        ut.expect(l_temp, 'one pk temp rows').to_equal(c_n * 2);
        merge_batch;
        pkg_deltaplan.finish_batch;

        ut.expect(pkg_deltaplan.next_batch, 'one pk second batch').to_be_false();

        pkg_deltaplan.finalize;
        ut.expect(tgt_count(), 'one pk tgt count').to_equal(c_n);
        ut.expect(tgt_cell(pk(1)), 'one pk lo cell').to_equal('2:1');
        ut.expect(tgt_cell(pk(c_n)), 'one pk hi cell')
            .to_equal(to_char(c_n + 1, 'TM9') || ':1');
    end one_pk_one_batch;

    procedure rollback_without_commit is
    begin
        load_a(1, c_n, c_t1);
        capture_source('inc_test_a');
        pkg_deltaplan.prepare_batches(p_batch_size => c_batch, p_commit => false);

        while pkg_deltaplan.next_batch loop
            merge_batch;
            pkg_deltaplan.finish_batch;
        end loop;

        rollback;
        ut.expect(tgt_state(), 'rollback tgt').to_be_null();
        pkg_deltaplan.finalize;
        ut.expect(wm('inc_test_a'), 'rollback wm').to_be_null();
    end rollback_without_commit;

end pkg_deltaplan_test;
/
