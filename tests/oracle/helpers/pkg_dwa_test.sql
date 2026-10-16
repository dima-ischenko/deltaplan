-- Shared fixture helpers. Cases live in tests/oracle/cases/.
create or replace package pkg_dwa_test is

    c_target constant varchar2(128) := 'inc_test_tgt';
    c_t1     constant date := timestamp '2024-01-15 10:00:00';
    c_t1b    constant date := timestamp '2024-01-15 10:00:01';
    c_t2     constant date := timestamp '2024-02-01 00:00:00';
    c_noon   constant date := timestamp '2024-06-01 12:00:00';

    procedure fail(p_test varchar2, p_detail varchar2);
    procedure eq(p_test varchar2, p_got varchar2, p_exp varchar2);
    procedure pass(p_test varchar2);
    procedure reset;
    procedure add_row(p_table varchar2, p_id varchar2, p_amount number, p_at date);
    procedure capture_source(p_table varchar2);
    procedure capture_both;
    procedure merge_all;
    procedure merge_batch;
    function key_count return varchar2;
    function wm(p_source varchar2) return varchar2;
    function tgt_state return varchar2;
    function ids_in_batch return varchar2;
    function seen(p_batch number) return varchar2;
    function tracking_count(p_target varchar2) return varchar2;
    procedure expect_error(p_test varchar2, p_code number);
    procedure volume(p_rows number);

end pkg_dwa_test;
/

create or replace package body pkg_dwa_test is

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

    procedure reset is
    begin
        delete from dwa_keys_tmp;
        delete from dwa_batch_tmp;
        delete from dwa_log;
        delete from dwa_watermark
        where target_table in (c_target, 'other_tgt');

        delete from inc_test_a;
        delete from inc_test_b;
        delete from inc_test_tgt;
        delete from inc_test_expect;
        delete from inc_test_seen;

        pkg_dwa.initialize(c_target, 'all', 0);
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
        pkg_dwa.capture_delta(
            p_source_table => p_table,
            p_sql =>
                'select id as pk_1,'
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
            from dwa_keys_tmp k
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
    end merge_all;

    procedure merge_batch is
    begin
        merge into inc_test_tgt t
        using (
            select k.pk_1 as id,
                   nvl(max(a.amount), 0) + nvl(max(b.amount), 0) as amount
            from dwa_batch_tmp k
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
            from dwa_keys_tmp
        );

        return to_char(l_cnt);
    end key_count;

    function wm(p_source varchar2) return varchar2 is
        l_value date;
    begin
        select watermark
        into l_value
        from dwa_watermark
        where target_table = c_target
          and data_slice = 'all'
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
        from dwa_batch_tmp;

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
        from dwa_watermark
        where target_table = p_target;

        return to_char(l_cnt);
    end tracking_count;

    procedure expect_error(p_test varchar2, p_code number) is
    begin
        fail(p_test, 'expected ' || p_code);
    end expect_error;

    procedure volume(p_rows number) is
        l_name  varchar2(32) := 'volume_' || to_char(p_rows);
        l_from  number;
        l_to    number;
        l_cnt   number;
        l_sum   number;
        l_tmin  number;
        l_tmax  number;
        l_touch number;
        c_chunk constant number := 100000;
    begin
        reset;

        l_from := 1;
        while l_from <= p_rows loop
            l_to := least(l_from + c_chunk - 1, p_rows);
            insert into inc_test_a (id, amount, updated_at)
            select to_char(l_from + level - 1, 'FM9999999999'),
                   1,
                   c_t1
            from dual
            connect by level <= (l_to - l_from + 1);
            l_from := l_to + 1;
        end loop;

        capture_source('inc_test_a');
        eq(l_name || ' keys', key_count, to_char(p_rows));
        merge_all;

        select count(*), sum(amount), min(touch), max(touch)
        into l_cnt, l_sum, l_tmin, l_tmax
        from inc_test_tgt;
        eq(l_name || ' tgt count', to_char(l_cnt), to_char(p_rows));
        eq(l_name || ' tgt sum', to_char(l_sum), to_char(p_rows));
        eq(l_name || ' tgt touch', l_tmin || ':' || l_tmax, '1:1');

        pkg_dwa.finalize;
        eq(l_name || ' wm', wm('inc_test_a'), '2024-01-15 10:00:00');

        pkg_dwa.initialize(c_target, 'all', 0);
        capture_source('inc_test_a');
        eq(l_name || ' second keys', key_count, '0');
        merge_all;
        pkg_dwa.finalize;
        select count(*) into l_cnt from inc_test_tgt;
        eq(l_name || ' second tgt count', to_char(l_cnt), to_char(p_rows));

        update inc_test_a
        set amount     = 2,
            updated_at = c_t2
        where id in (
            to_char(1, 'FM9999999999'),
            to_char(trunc(p_rows / 2), 'FM9999999999'),
            to_char(p_rows, 'FM9999999999')
        );

        pkg_dwa.initialize(c_target, 'all', 0);
        capture_source('inc_test_a');
        eq(l_name || ' delta keys', key_count, '3');
        merge_all;
        pkg_dwa.finalize;

        select count(*), sum(amount), min(touch), max(touch)
        into l_cnt, l_sum, l_tmin, l_tmax
        from inc_test_tgt;
        eq(l_name || ' delta count', to_char(l_cnt), to_char(p_rows));
        eq(l_name || ' delta sum', to_char(l_sum), to_char(p_rows + 3));
        eq(l_name || ' delta touch', l_tmin || ':' || l_tmax, '1:2');

        select touch
        into l_touch
        from inc_test_tgt
        where id = to_char(1, 'FM9999999999');
        eq(l_name || ' delta row', to_char(l_touch), '2');
        eq(l_name || ' delta wm', wm('inc_test_a'), '2024-02-01 00:00:00');
        pass(l_name);
    end volume;

end pkg_dwa_test;
/
