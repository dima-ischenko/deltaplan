create or replace package body pkg_deltaplan is

    gv_target_table    varchar2(128);
    gv_data_segment    varchar2(64);
    gv_lookback_hours  number := 0;
    gv_batch_no        number;
    gv_batch_size      number;
    gv_batch_commit    boolean := true;
    gv_batches_ready   boolean := false;
    gv_keys_durable    boolean := false;
    gv_apply_open      boolean := false;
    gv_output_ready    boolean := false;
    gv_run_started     timestamp;
    gv_batch_started   timestamp;

    function get_proc_name(p_proc_name varchar2) return varchar2 is
    begin
        return 'pkg_deltaplan.' || p_proc_name;
    end get_proc_name;

    function fmt_date(p_date date) return varchar2 is
    begin
        return nvl(to_char(p_date, 'yyyy-mm-dd hh24:mi:ss'), 'null');
    end fmt_date;

    function fmt_num(p_value number) return varchar2 is
    begin
        return nvl(to_char(p_value), 'null');
    end fmt_num;

    function seconds_since(p_from timestamp) return number is
        l_delta interval day to second := systimestamp - p_from;
    begin
        return extract(day from l_delta) * 86400
             + extract(hour from l_delta) * 3600
             + extract(minute from l_delta) * 60
             + extract(second from l_delta);
    end seconds_since;

    procedure i_log(p_proc_name varchar2,
                    p_rows      number,
                    p_text      varchar2 default null) is
    begin
        if not gv_output_ready then
            dbms_output.enable(buffer_size => null);
            gv_output_ready := true;
        end if;

        dbms_output.put_line(
            to_char(systimestamp, 'hh24:mi:ss.ff3') || ' '
            || p_proc_name || ': '
            || rpad(p_rows, 16) || '|'
            || p_text
        );
    end i_log;

    procedure assert_ready is
    begin
        if gv_target_table is null then
            raise_application_error(-20001, 'Call initialize first');
        end if;
    end assert_ready;

    function placeholder_count(p_sql varchar2, p_name varchar2) return number is
        l_sql  varchar2(32767) := lower(p_sql);
        l_name varchar2(128) := lower(p_name);
        l_cnt  number := 0;
        l_pos  number := 1;
        l_next varchar2(1);
    begin
        loop
            l_pos := instr(l_sql, l_name, l_pos);
            exit when l_pos = 0;

            l_next := substr(l_sql, l_pos + length(l_name), 1);
            if l_next is null or regexp_instr(l_next, '[a-z0-9_$#]') = 0 then
                l_cnt := l_cnt + 1;
            end if;

            l_pos := l_pos + length(l_name);
        end loop;

        return l_cnt;
    end placeholder_count;

    function unfinished_batches return number is
        l_left number;
    begin
        select count(distinct batch_no)
        into l_left
        from dpl_keys_tmp
        where target_table = gv_target_table
          and data_segment = gv_data_segment
          and batch_no is not null
          and batch_done = 0;

        return l_left;
    end unfinished_batches;

    function batch_total return number is
        l_total number;
    begin
        select count(distinct batch_no)
        into l_total
        from dpl_keys_tmp
        where target_table = gv_target_table
          and data_segment = gv_data_segment
          and batch_no is not null;

        return l_total;
    end batch_total;

    function unassigned_keys return number is
        l_cnt number;
    begin
        select count(*)
        into l_cnt
        from dpl_keys_tmp
        where target_table = gv_target_table
          and data_segment = gv_data_segment
          and batch_no is null
          and rownum = 1;

        return l_cnt;
    end unassigned_keys;

    procedure note_failure(
        p_proc_name varchar2,
        p_rows      number,
        p_error     varchar2
    ) is
        l_left       number;
        l_unassigned number;
    begin
        i_log(
            p_proc_name,
            nvl(p_rows, 0),
            'failed batch=' || nvl(to_char(gv_batch_no), 'none') || ' ' || p_error
        );
        rollback;
        gv_batch_no := null;

        l_left := unfinished_batches;
        l_unassigned := unassigned_keys;

        if gv_keys_durable then
            gv_batches_ready := true;
            gv_apply_open := l_left > 0 or l_unassigned > 0;
            if l_left = 0 and l_unassigned > 0 then
                i_log(p_proc_name, l_unassigned, 'batch numbers were rolled back, call prepare_batches');
            else
                i_log(
                    p_proc_name,
                    l_left,
                    'captured keys are committed, unfinished=' || l_left
                    || ', call next_batch to resume'
                );
            end if;
        else
            gv_apply_open := false;
            gv_batches_ready := false;
            gv_batch_size := null;
            i_log(p_proc_name, 0, 'rolled back, call initialize before the next run');
        end if;
    end note_failure;

    function get_target_table return varchar2 is
    begin
        return gv_target_table;
    end get_target_table;

    function get_data_segment return varchar2 is
    begin
        return gv_data_segment;
    end get_data_segment;

    function get_lookback_hours return number is
    begin
        return gv_lookback_hours;
    end get_lookback_hours;

    function get_batch_no return number is
    begin
        return gv_batch_no;
    end get_batch_no;

    function get_watermark(p_source_table varchar2) return date is
        l_result date;
    begin
        select max(watermark)
        into l_result
        from dpl_watermark
        where target_table = gv_target_table
          and source_table = p_source_table
          and data_segment = gv_data_segment;

        return coalesce(l_result, date '2000-01-01');
    end get_watermark;

    procedure initialize(
        p_target_table    varchar2,
        p_data_segment    varchar2 default 'all',
        p_lookback_hours  number   default 0
    ) is
        l_proc_name  varchar2(64) := get_proc_name('initialize');
        l_started    timestamp := systimestamp;
        l_rows       number := 0;
        l_batch_rows number := 0;
    begin
        if p_target_table is null then
            raise_application_error(-20006, 'target_table is required');
        end if;

        if p_data_segment is null then
            raise_application_error(-20006, 'data_segment is required');
        end if;

        if nvl(p_lookback_hours, 0) < 0 then
            raise_application_error(-20002, 'lookback_hours must be >= 0');
        end if;

        begin
        gv_target_table := lower(p_target_table);
        gv_data_segment := lower(p_data_segment);
        gv_lookback_hours := nvl(p_lookback_hours, 0);
        gv_batch_no := null;
        gv_batch_size := null;
        gv_batch_commit := true;
        gv_batches_ready := false;
        gv_keys_durable := false;
        gv_apply_open := false;

        delete from dpl_keys_tmp
        where target_table = gv_target_table
          and data_segment = gv_data_segment;
        l_rows := sql%rowcount;

        delete from dpl_batch_tmp;
        l_batch_rows := sql%rowcount;

        i_log(
            l_proc_name,
            l_rows,
            'target=' || gv_target_table
            || ' segment=' || gv_data_segment
            || ' lookback_hours=' || fmt_num(gv_lookback_hours)
            || ' deleted_temp=' || l_rows
            || ' deleted_batch=' || l_batch_rows
            || ' ' || fmt_num(round(seconds_since(l_started), 3)) || 's'
        );
    exception
        when others then
            i_log(l_proc_name, 0, 'failed ' || sqlerrm);
            rollback;
            gv_target_table := null;
            gv_data_segment := null;
            gv_batch_no := null;
            gv_batch_size := null;
            gv_batch_commit := true;
            gv_batches_ready := false;
            gv_keys_durable := false;
            gv_apply_open := false;
            raise;
        end;
    end initialize;

    procedure capture_delta(
        p_source_table    varchar2,
        p_sql             varchar2,
        p_lookback_hours  number default null
    ) is
        l_proc_name    varchar2(64) := get_proc_name('capture_delta');
        l_started      timestamp := systimestamp;
        l_source_table varchar2(128) := lower(p_source_table);
        l_lookback     number;
        l_watermark    date;
        l_bound        date;
        l_insert_sql   clob;
        l_rows         number := 0;
        l_slice_rows   number := 0;
        l_slice_pk     number := 0;
        l_min          date;
        l_max          date;
    begin
        assert_ready;

        if l_source_table is null then
            raise_application_error(-20006, 'source_table is required');
        end if;

        if p_sql is null then
            raise_application_error(-20006, 'capture sql is required');
        end if;

        if placeholder_count(p_sql, ':since') != 1 then
            raise_application_error(-20015, 'capture SQL must contain :since exactly once');
        end if;

        l_lookback := coalesce(p_lookback_hours, gv_lookback_hours, 0);

        if l_lookback < 0 then
            raise_application_error(-20002, 'lookback_hours must be >= 0');
        end if;

        if gv_batches_ready or gv_apply_open or unfinished_batches > 0 then
            raise_application_error(-20013, 'capture_delta is closed after prepare_batches until finalize');
        end if;

        l_watermark := get_watermark(l_source_table);
        -- Date arithmetic keeps the bound as DATE. Hours are a fraction of a day.
        l_bound := l_watermark - l_lookback / 24;

        begin
        l_insert_sql := '
            begin
                insert into dpl_keys_tmp (
                    target_table,
                    data_segment,
                    source_table,
                    pk_1,
                    pk_2,
                    pk_3,
                    watermark
                )
                select
                    :target_table,
                    :data_segment,
                    :source_table,
                    s.pk_1,
                    s.pk_2,
                    s.pk_3,
                    s.watermark
                from (' || p_sql || ') s;
                :cnt_out := sql%rowcount;
            end;';

        execute immediate l_insert_sql
            using in gv_target_table, in gv_data_segment, in l_source_table, in l_bound,
                  out l_rows;

        select count(*), min(watermark), max(watermark)
        into l_slice_rows, l_min, l_max
        from dpl_keys_tmp
        where target_table = gv_target_table
          and data_segment = gv_data_segment
          and source_table = l_source_table;

        select count(*)
        into l_slice_pk
        from (
            select distinct pk_1, pk_2, pk_3
            from dpl_keys_tmp
            where target_table = gv_target_table
              and data_segment = gv_data_segment
              and source_table = l_source_table
        );

        i_log(
            l_proc_name,
            l_rows,
            'source=' || l_source_table
            || ' stored=' || fmt_date(l_watermark)
            || ' lookback_hours=' || fmt_num(l_lookback)
            || ' bound=' || fmt_date(l_bound)
            || ' predicate=value > bound'
            || ' inserted=' || l_rows
            || ' slice_rows=' || l_slice_rows
            || ' slice_pk=' || l_slice_pk
            || ' min=' || fmt_date(l_min)
            || ' max=' || fmt_date(l_max)
            || ' ' || fmt_num(round(seconds_since(l_started), 3)) || 's'
        );
    exception
        when others then
            i_log(l_proc_name, nvl(l_rows, 0), 'source=' || l_source_table || ' failed ' || sqlerrm);
            rollback;
            raise;
        end;
    end capture_delta;

    procedure prepare_batches(
        p_batch_size  number  default 5000,
        p_commit      boolean default true
    ) is
        l_proc_name  varchar2(64) := get_proc_name('prepare_batches');
        l_commit     boolean := true;
        l_batch_size number := p_batch_size;
        l_assigned   number := 0;
        l_open       number := 0;
        l_key_total  number := 0;
        l_left       number := 0;
    begin
        assert_ready;

        if p_commit = false then
            l_commit := false;
        end if;

        if l_batch_size is null or l_batch_size < 1 or l_batch_size != trunc(l_batch_size) then
            raise_application_error(-20003, 'batch_size must be a positive integer');
        end if;

        select count(*)
        into l_key_total
        from (
            select distinct pk_1, pk_2, pk_3
            from dpl_keys_tmp
            where target_table = gv_target_table
              and data_segment = gv_data_segment
        );

        select count(*)
        into l_assigned
        from dpl_keys_tmp
        where target_table = gv_target_table
          and data_segment = gv_data_segment
          and batch_no is not null
          and rownum = 1;

        if l_assigned > 0 and gv_batch_size is not null and l_batch_size != gv_batch_size then
            raise_application_error(
                -20009,
                'batch_size cannot change while batches are in progress, current=' || gv_batch_size
            );
        end if;

        if l_assigned > 0 and gv_batch_size is not null and l_commit != gv_batch_commit then
            raise_application_error(-20018, 'p_commit cannot change while batches are in progress');
        end if;

        if gv_batch_no is not null then
            select count(*)
            into l_open
            from dpl_batch_tmp
            where rownum = 1;

            if l_open > 0 then
                raise_application_error(
                    -20014,
                    'batch ' || gv_batch_no || ' is open; call finish_batch'
                );
            end if;
        end if;

        gv_run_started := systimestamp;
        gv_batch_commit := l_commit;
        gv_batches_ready := true;
        gv_batch_no := null;

        if l_key_total = 0 then
            gv_apply_open := false;
            i_log(
                l_proc_name,
                0,
                'no keys, nothing to apply ' || fmt_num(round(seconds_since(gv_run_started), 3)) || 's'
            );
            return;
        end if;

        gv_batch_size := l_batch_size;

        begin
            -- Captured keys must survive a failed batch. Otherwise a retry
            -- would rebuild the batch list from a temporary table that had been rolled back.
            if l_commit then
                commit;
                gv_keys_durable := true;
                i_log(l_proc_name, l_key_total, 'committed captured keys before batches');
            end if;

            if l_assigned = 0 then
                merge into dpl_keys_tmp t
                using (
                    select pk_1,
                           pk_2,
                           pk_3,
                           ceil(row_number() over (
                               order by pk_1, pk_2 nulls first, pk_3 nulls first
                           ) / l_batch_size) as batch_no
                    from (
                        select distinct pk_1, pk_2, pk_3
                        from dpl_keys_tmp
                        where target_table = gv_target_table
                          and data_segment = gv_data_segment
                    )
                ) s
                on (t.target_table = gv_target_table
                    and t.data_segment = gv_data_segment
                    and t.pk_1 = s.pk_1
                    and decode(t.pk_2, s.pk_2, 1, 0) = 1
                    and decode(t.pk_3, s.pk_3, 1, 0) = 1)
                when matched then update
                    set t.batch_no = s.batch_no,
                        t.batch_done = 0
                    where t.batch_no is null;

                if sql%rowcount = 0 then
                    raise_application_error(-20011, 'batch numbers were not assigned');
                end if;

                i_log(
                    l_proc_name,
                    sql%rowcount,
                    'assigned batch_no batch_size=' || l_batch_size
                    || ' distinct_pk=' || l_key_total
                    || case when l_commit then ' commit' else ' no_commit' end
                );

                if l_commit then
                    commit;
                end if;
            else
                i_log(
                    l_proc_name,
                    l_key_total,
                    'resume batch_size=' || gv_batch_size
                    || case when l_commit then ' commit' else ' no_commit' end
                );
            end if;

            l_left := unfinished_batches;

            if l_left = 0 then
                gv_apply_open := false;
                i_log(l_proc_name, 0, 'nothing left to apply batches=' || batch_total);
                return;
            end if;

            gv_apply_open := true;
        exception
            when others then
                note_failure(l_proc_name, l_key_total, sqlerrm);
                raise;
        end;
    end prepare_batches;

    procedure load_batch_keys(p_batch_no number, p_keys out number) is
    begin
        delete from dpl_batch_tmp;

        insert into dpl_batch_tmp (pk_1, pk_2, pk_3)
        select distinct pk_1, pk_2, pk_3
        from dpl_keys_tmp
        where target_table = gv_target_table
          and data_segment = gv_data_segment
          and batch_no = p_batch_no
          and batch_done = 0;

        p_keys := sql%rowcount;
    end load_batch_keys;

    function next_batch return boolean is
        l_proc_name varchar2(64) := get_proc_name('next_batch');
        l_open      number := 0;
        l_keys      number := 0;
        l_next      number;
        l_total     number;
    begin
        assert_ready;

        if not gv_batches_ready then
            raise_application_error(-20016, 'Call prepare_batches first');
        end if;

        if gv_batch_no is not null then
            select count(*)
            into l_open
            from dpl_batch_tmp
            where rownum = 1;

            if l_open > 0 then
                raise_application_error(
                    -20014,
                    'batch ' || gv_batch_no || ' is open; call finish_batch'
                );
            end if;
        end if;

        if not gv_apply_open and gv_batch_no is null then
            return false;
        end if;

        begin
            if gv_batch_no is not null then
                load_batch_keys(gv_batch_no, l_keys);

                if l_keys > 0 then
                    gv_batch_started := systimestamp;
                    i_log(
                        l_proc_name,
                        l_keys,
                        'batch ' || gv_batch_no || '/' || batch_total
                        || ' keys=' || l_keys || ' reopened'
                    );
                    return true;
                end if;

                gv_batch_no := null;
            end if;

            select min(batch_no)
            into l_next
            from dpl_keys_tmp
            where target_table = gv_target_table
              and data_segment = gv_data_segment
              and batch_no is not null
              and batch_done = 0;

            if l_next is null then
                if unassigned_keys > 0 then
                    raise_application_error(-20011, 'batch numbers are missing; call prepare_batches');
                end if;

                gv_batch_no := null;
                gv_apply_open := false;
                delete from dpl_batch_tmp;
                i_log(l_proc_name, 0, 'nothing left to apply batches=' || batch_total);
                return false;
            end if;

            load_batch_keys(l_next, l_keys);

            if l_keys = 0 then
                raise_application_error(-20011, 'batch ' || l_next || ' has no keys');
            end if;

            gv_batch_no := l_next;
            gv_batch_started := systimestamp;
            l_total := batch_total;

            i_log(
                l_proc_name,
                l_keys,
                'batch ' || gv_batch_no || '/' || l_total || ' keys=' || l_keys || ' opened'
            );
            return true;
        exception
            when others then
                note_failure(l_proc_name, l_keys, sqlerrm);
                raise;
        end;
    end next_batch;

    procedure finish_batch is
        -- Still the caller's DML row count: this procedure has not executed any SQL yet.
        l_merged    number := sql%rowcount;
        l_proc_name varchar2(64) := get_proc_name('finish_batch');
        l_batch_no  number := gv_batch_no;
        l_total     number;
    begin
        assert_ready;

        if l_batch_no is null then
            raise_application_error(-20017, 'No open batch; call next_batch');
        end if;

        begin
            update dpl_keys_tmp
            set batch_done = 1
            where target_table = gv_target_table
              and data_segment = gv_data_segment
              and batch_no = l_batch_no
              and batch_done = 0;

            if sql%rowcount = 0 then
                raise_application_error(-20012, 'batch ' || l_batch_no || ' was not marked done');
            end if;

            l_total := batch_total;

            if gv_batch_commit then
                commit;
            else
                delete from dpl_batch_tmp;
            end if;

            gv_batch_no := null;

            if unfinished_batches = 0 then
                gv_apply_open := false;
            end if;

            i_log(
                l_proc_name,
                l_merged,
                'batch ' || l_batch_no || '/' || l_total
                || ' merged=' || l_merged
                || case when gv_batch_commit then ' committed' else ' uncommitted' end
                || ' batch_s=' || fmt_num(round(seconds_since(gv_batch_started), 3))
                || ' total_s=' || fmt_num(round(seconds_since(gv_run_started), 3))
            );
        exception
            when others then
                note_failure(l_proc_name, l_merged, sqlerrm);
                raise;
        end;
    end finish_batch;

    procedure store_watermark(
        p_source_table varchar2,
        p_effective    date,
        p_moved        out number
    ) is
    begin
        merge into dpl_watermark t
        using (
            select gv_target_table as target_table,
                   gv_data_segment as data_segment,
                   p_source_table  as source_table,
                   p_effective     as watermark
            from dual
        ) s
        on (t.target_table = s.target_table
            and t.data_segment = s.data_segment
            and t.source_table = s.source_table)
        when matched then
            update set t.watermark = s.watermark,
                       t.updated_at = sysdate
            where t.watermark < s.watermark
        when not matched then
            insert (target_table, data_segment, source_table, watermark, updated_at)
            values (s.target_table, s.data_segment, s.source_table, s.watermark, sysdate);

        p_moved := sql%rowcount;
    exception
        when dup_val_on_index then
            update dpl_watermark
            set watermark = p_effective,
                updated_at = sysdate
            where target_table = gv_target_table
              and data_segment = gv_data_segment
              and source_table = p_source_table
              and watermark < p_effective;

            p_moved := sql%rowcount;
    end store_watermark;

    procedure finalize is
        l_proc_name varchar2(64) := get_proc_name('finalize');
        l_started   timestamp := systimestamp;
        l_all_pk    number := 0;
        l_sources   number := 0;
        l_left       number := 0;
        l_unassigned number := 0;
        l_old        date;
        l_effective date;
        l_moved     number := 0;
        l_effect    varchar2(16);
    begin
        assert_ready;
        l_left := unfinished_batches;

        select count(*)
        into l_all_pk
        from (
            select distinct pk_1, pk_2, pk_3
            from dpl_keys_tmp
            where target_table = gv_target_table
              and data_segment = gv_data_segment
        );

        select count(*)
        into l_unassigned
        from dpl_keys_tmp
        where target_table = gv_target_table
          and data_segment = gv_data_segment
          and batch_no is null
          and rownum = 1;

        if l_left > 0
           or (gv_apply_open and l_all_pk > 0)
           or (gv_batches_ready and l_unassigned > 0) then
            raise_application_error(
                -20005,
                'unfinished batches for ' || gv_target_table
                || ' (' || l_left || ' left). Watermark was not moved. '
                || 'Call prepare_batches, then next_batch and finish_batch, to resume.'
            );
        end if;

        gv_apply_open := false;
        gv_batches_ready := false;

        for ir in (
            select s.source_table,
                   s.watermark,
                   s.src_rows,
                   p.pk_rows
            from (
                select source_table,
                       max(watermark) watermark,
                       count(*) src_rows
                from dpl_keys_tmp
                where target_table = gv_target_table
                  and data_segment = gv_data_segment
                group by source_table
            ) s
            join (
                select source_table, count(*) pk_rows
                from (
                    select distinct source_table, pk_1, pk_2, pk_3
                    from dpl_keys_tmp
                    where target_table = gv_target_table
                      and data_segment = gv_data_segment
                )
                group by source_table
            ) p
              on p.source_table = s.source_table
            order by s.source_table
        ) loop
            l_sources := l_sources + 1;

            begin
                select watermark
                into l_old
                from dpl_watermark
                where target_table = gv_target_table
                  and data_segment = gv_data_segment
                  and source_table = ir.source_table;
            exception
                when no_data_found then
                    l_old := null;
            end;

            if l_old is null or ir.watermark > l_old then
                l_effective := ir.watermark;
            else
                l_effective := l_old;
            end if;

            if l_old is null then
                l_effect := 'inserted';
            elsif ir.watermark > l_old then
                l_effect := 'advanced';
            elsif ir.watermark < l_old then
                l_effect := 'kept';
            else
                l_effect := 'unchanged';
            end if;

            store_watermark(ir.source_table, l_effective, l_moved);

            i_log(
                l_proc_name,
                ir.pk_rows,
                'source=' || ir.source_table
                || ' stored=' || fmt_date(l_old)
                || ' captured=' || fmt_date(ir.watermark)
                || ' effective=' || fmt_date(l_effective)
                || ' ' || l_effect
                || ' moved=' || l_moved
                || ' rows=' || ir.src_rows
                || ' pk=' || ir.pk_rows
                || ' all_pk=' || l_all_pk
            );
        end loop;

        if l_sources = 0 then
            i_log(l_proc_name, 0, 'no delta, watermarks unchanged');
        end if;

        i_log(
            l_proc_name,
            l_all_pk,
            'sources=' || l_sources
            || ' distinct_pk=' || l_all_pk
            || ' ' || fmt_num(round(seconds_since(l_started), 3)) || 's'
        );

        delete from dpl_batch_tmp;

        gv_target_table := null;
        gv_data_segment := null;
        gv_lookback_hours := 0;
        gv_batch_no := null;
        gv_batch_size := null;
        gv_apply_open := false;
    exception
        when others then
            i_log(l_proc_name, nvl(l_all_pk, 0), 'failed ' || sqlerrm);
            if sqlcode != -20005 then
                rollback;
            end if;
            raise;
    end finalize;

end pkg_deltaplan;
