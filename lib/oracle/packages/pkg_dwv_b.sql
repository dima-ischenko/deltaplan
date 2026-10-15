create or replace package body pkg_dwv is

gv_target_owner    varchar2(128);
gv_target_table    varchar2(128);
gv_data_slice      varchar2(64);
gv_lookback_hours  number := 0;
gv_batch_no        number;
gv_batch_size      number;
gv_batch_total     number;
gv_commit_batch    boolean := true;
gv_batches_ready   boolean := false;
gv_output_ready    boolean := false;
gv_debug           boolean := false;
gv_log_table       boolean := false;
gv_lockhandle      varchar2(128);
gv_lockname        varchar2(128);

c_w_proc   constant pls_integer := 26;
c_w_name   constant pls_integer := 28;
c_w_date   constant pls_integer := 32;
c_w_batch  constant pls_integer := 18;
c_w_slice  constant pls_integer := 16;

-- dbms_lock.request return codes
-- 0 success
-- 1 timeout
-- 2 deadlock
-- 3 parameter error
-- 4 already own lock
-- 5 illegal lock handle
c_lock_success     constant number := 0;
c_lock_timeout     constant number := 1;
c_lock_deadlock    constant number := 2;
c_lock_param_error constant number := 3;
c_lock_already_own constant number := 4;
c_lock_illegal     constant number := 5;

function get_proc_name(p_proc_name varchar2) return varchar2 is
begin
    return 'pkg_dwv.' || p_proc_name;
end get_proc_name;

function fmt_date(p_date date) return varchar2 is
begin
    return nvl(to_char(p_date, 'yyyy-mm-dd hh24:mi:ss'), 'null');
end fmt_date;

function fmt_num(p_value number) return varchar2 is
begin
    return nvl(to_char(p_value), 'null');
end fmt_num;

-- rpad without truncating a value that is already wider than p_width.
function fmt_col(p_text varchar2, p_width number) return varchar2 is
    l_text varchar2(4000) := nvl(p_text, 'null');
begin
    if length(l_text) >= p_width then
        return l_text || ' ';
    end if;
    return rpad(l_text, p_width);
end fmt_col;

function seconds_since(p_from timestamp) return number is
    l_delta interval day to second := systimestamp - p_from;
begin
    return extract(day from l_delta) * 86400
         + extract(hour from l_delta) * 3600
         + extract(minute from l_delta) * 60
         + extract(second from l_delta);
end seconds_since;

function lock_request_meaning(p_rc number) return varchar2 is
begin
    return case p_rc
        when c_lock_success     then 'success'
        when c_lock_timeout     then 'timeout'
        when c_lock_deadlock    then 'deadlock'
        when c_lock_param_error then 'parameter error'
        when c_lock_already_own then 'already own lock'
        when c_lock_illegal     then 'illegal lock handle'
        else 'unknown'
    end;
end lock_request_meaning;

function norm_ident(p_name varchar2, p_label varchar2) return varchar2 is
    l_name varchar2(128);
begin
    if p_name is null then
        raise_application_error(-20006, p_label || ' is required');
    end if;

    l_name := lower(trim(p_name));

    if l_name is null then
        raise_application_error(-20006, p_label || ' is required');
    end if;

    if instr(l_name, '.') > 0 then
        raise_application_error(
            -20006,
            p_label || ' must be unqualified; pass p_owner for the schema'
        );
    end if;

    if not regexp_like(l_name, '^[a-z][a-z0-9_#$]*$') then
        raise_application_error(-20022, 'invalid ' || p_label || ' ' || p_name);
    end if;

    return l_name;
end norm_ident;

function resolve_owner(p_owner varchar2) return varchar2 is
    l_owner varchar2(128);
begin
    l_owner := lower(trim(p_owner));
    if l_owner is null then
        l_owner := lower(sys_context('USERENV', 'CURRENT_SCHEMA'));
    end if;
    return norm_ident(l_owner, 'owner');
end resolve_owner;

procedure assert_relation(p_owner varchar2, p_table varchar2) is
    l_n number;
begin
    select count(*)
    into l_n
    from all_objects
    where owner = upper(p_owner)
      and object_name = upper(p_table)
      and object_type in ('TABLE', 'VIEW', 'MATERIALIZED VIEW')
      and rownum = 1;

    if l_n = 0 then
        raise_application_error(
            -20022,
            'table ' || p_owner || '.' || p_table || ' does not exist or is not available'
        );
    end if;

    begin
        execute immediate
            'select null from ' || p_owner || '.' || p_table || ' where 1 = 0';
    exception
        when others then
            raise_application_error(
                -20022,
                'table ' || p_owner || '.' || p_table || ' does not exist or is not available'
            );
    end;
end assert_relation;

procedure write_log_row(
    p_proc_name varchar2,
    p_rows      number,
    p_text      varchar2
) is
    pragma autonomous_transaction;
begin
    insert into dwv_log (
        logged_at,
        proc_name,
        target_owner,
        target_table,
        data_slice,
        batch_no,
        log_rows,
        message
    ) values (
        systimestamp,
        p_proc_name,
        gv_target_owner,
        gv_target_table,
        gv_data_slice,
        gv_batch_no,
        p_rows,
        substr(p_text, 1, 4000)
    );
    commit;
end write_log_row;

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
        || rpad(p_proc_name || ':', c_w_proc)
        || rpad(p_rows, 16) || '| '
        || p_text
    );

    if gv_log_table then
        write_log_row(
            p_proc_name,
            p_rows,
            p_text
        );
    end if;
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

-- True when (p_sql) exposes p_col. Inner SQL errors other than a missing
-- p_col are re-raised. where 1 = 0 keeps this a parse of the shape only.
function capture_has_col(
    p_sql   varchar2,
    p_bound date,
    p_col   varchar2
) return boolean is
    l_n number;
begin
    execute immediate
        'select count(*) from (select s.' || p_col
        || ' from (' || p_sql || ') s where 1 = 0)'
        into l_n
        using p_bound;
    return true;
exception
    when others then
        if sqlcode = -904
           and instr(upper(sqlerrm), '"' || upper(p_col) || '"') > 0 then
            return false;
        end if;
        raise;
end capture_has_col;

function unfinished_batches return number is
    l_left number;
begin
    select count(*)
    into l_left
    from dwv_keys_tmp
    where batch_no is not null
      and batch_done = 0
      and rownum = 1;

    return l_left;
end unfinished_batches;

procedure note_failure(
    p_proc_name varchar2,
    p_rows      number,
    p_error     varchar2
) is
begin
    i_log(
        p_proc_name,
        nvl(p_rows, 0),
        'failed batch=' || nvl(to_char(gv_batch_no), 'none') || ' ' || p_error
    );
    rollback;
    gv_batch_no := null;
    gv_batch_size := null;
    gv_batch_total := null;
    gv_commit_batch := true;
    gv_batches_ready := false;
    i_log(p_proc_name, 0, 'rolled back, call initialize before the next run');
end note_failure;

procedure assert_no_open_batch is
    l_open number := 0;
begin
    if gv_batch_no is null then
        return;
    end if;

    select count(*)
    into l_open
    from dwv_batch_tmp
    where rownum = 1;

    if l_open > 0 then
        raise_application_error(
            -20014,
            'batch ' || gv_batch_no || ' is open; call finish_batch'
        );
    end if;

    raise_application_error(
        -20019,
        'batch ' || gv_batch_no || ' lost its keys; call initialize'
    );
end assert_no_open_batch;

function get_target_owner return varchar2 is
begin
    return gv_target_owner;
end get_target_owner;

function get_target_table return varchar2 is
begin
    return gv_target_table;
end get_target_table;

function get_data_slice return varchar2 is
begin
    return gv_data_slice;
end get_data_slice;

function get_batch_no return number is
begin
    return gv_batch_no;
end get_batch_no;

procedure set_log_table(p_enabled boolean default true) is
begin
    if p_enabled then
        gv_log_table := true;
    else
        gv_log_table := false;
    end if;
end set_log_table;

-- Named lock, same idea as lock_utl: ALLOCATE_UNIQUE(name) then REQUEST(handle).
-- REQUEST has no name overload. ALLOCATE_UNIQUE writes DBMS_LOCK_ALLOCATED;
-- the autonomous commit keeps that out of the caller's transaction.
function run_lock_name(
    p_owner   varchar2,
    p_target  varchar2,
    p_slice   varchar2
) return varchar2 is
begin
    return substr('DWV|' || p_owner || '.' || p_target || '|' || p_slice, 1, 128);
end run_lock_name;

function allocate_lock_handle(p_name varchar2) return varchar2 is
    pragma autonomous_transaction;
    l_handle varchar2(128);
begin
    dbms_lock.allocate_unique(p_name, l_handle);
    commit;
    return l_handle;
end allocate_lock_handle;

procedure acquire_run_lock(
    p_owner  varchar2,
    p_target varchar2,
    p_slice  varchar2
) is
    l_name   varchar2(128) := run_lock_name(p_owner, p_target, p_slice);
    l_handle varchar2(128);
    l_rc     number;
    l_proc   varchar2(64) := get_proc_name('initialize');
begin
    if gv_lockname = l_name and gv_lockhandle is not null then
        i_log(l_proc, 0, 'lock already held name=' || l_name);
        return;
    end if;

    if gv_lockhandle is not null then
        l_rc := dbms_lock.release(gv_lockhandle);
        i_log(l_proc, 0, 'lock released name=' || gv_lockname);
        gv_lockhandle := null;
        gv_lockname := null;
    end if;

    l_handle := allocate_lock_handle(l_name);
    l_rc := dbms_lock.request(
        lockhandle        => l_handle,
        lockmode          => dbms_lock.x_mode,
        timeout           => 0,
        release_on_commit => false
    );

    -- 0 success, 4 already own lock. 1 timeout means another session holds it.
    if l_rc not in (c_lock_success, c_lock_already_own) then
        i_log(
            l_proc,
            0,
            'lock request rc=' || l_rc
            || ' ' || lock_request_meaning(l_rc)
            || ' name=' || l_name
        );
        if l_rc = c_lock_timeout then
            raise_application_error(
                -20021,
                'another run is active for ' || p_owner || '.' || p_target || ' / ' || p_slice
            );
        end if;
        raise_application_error(
            -20021,
            'lock request failed (' || lock_request_meaning(l_rc)
            || ') for ' || p_owner || '.' || p_target || ' / ' || p_slice
        );
    end if;

    gv_lockhandle := l_handle;
    gv_lockname := l_name;
    if l_rc = c_lock_already_own then
        i_log(l_proc, 0, 'lock already held name=' || l_name);
    else
        i_log(l_proc, 0, 'lock acquired name=' || l_name);
    end if;
end acquire_run_lock;

procedure release_run_lock is
    l_rc   number;
    l_name varchar2(128) := gv_lockname;
begin
    if gv_lockhandle is null then
        return;
    end if;

    begin
        l_rc := dbms_lock.release(gv_lockhandle);
    exception
        when others then
            null;
    end;
    gv_lockhandle := null;
    gv_lockname := null;
    i_log(get_proc_name('finalize'), 0, 'lock released name=' || l_name);
end release_run_lock;

function get_watermark(
    p_source_owner varchar2,
    p_source_table varchar2
) return date is
    l_result date;
begin
    select max(watermark)
    into l_result
    from dwv_watermark
    where target_owner = gv_target_owner
      and target_table = gv_target_table
      and source_owner = p_source_owner
      and source_table = p_source_table
      and data_slice = gv_data_slice;

    return coalesce(l_result, date '2000-01-01');
end get_watermark;

procedure initialize(
    p_target_table    varchar2,
    p_data_slice      varchar2 default 'all',
    p_lookback_hours  number   default 0,
    p_debug           boolean  default false,
    p_owner           varchar2 default null
) is
    l_proc_name  varchar2(64) := get_proc_name('initialize');
    l_started    timestamp := systimestamp;
    l_owner      varchar2(128);
    l_target     varchar2(128);
    l_slice      varchar2(64);
    l_rows       number := 0;
    l_batch_rows number := 0;
begin
    l_owner := resolve_owner(p_owner);
    l_target := norm_ident(p_target_table, 'target_table');
    l_slice := norm_ident(p_data_slice, 'data_slice');

    if nvl(p_lookback_hours, 0) < 0 then
        raise_application_error(-20002, 'lookback_hours must be >= 0');
    end if;

    assert_relation(l_owner, l_target);

    begin
    gv_target_owner := l_owner;
    gv_target_table := l_target;
    gv_data_slice := l_slice;
    acquire_run_lock(gv_target_owner, gv_target_table, gv_data_slice);
    gv_lookback_hours := nvl(p_lookback_hours, 0);
    if p_debug then
        gv_debug := true;
    else
        gv_debug := false;
    end if;
    gv_batch_no := null;
    gv_batch_size := null;
    gv_batch_total := null;
    gv_commit_batch := true;
    gv_batches_ready := false;

    delete from dwv_keys_tmp;
    l_rows := sql%rowcount;

    delete from dwv_batch_tmp;
    l_batch_rows := sql%rowcount;

    i_log(
        l_proc_name,
        l_rows,
        fmt_col('target=' || gv_target_owner || '.' || gv_target_table, c_w_name)
        || fmt_col('slice=' || gv_data_slice, c_w_slice)
        || 'lookback_hours=' || fmt_num(gv_lookback_hours)
        || ' deleted_temp=' || l_rows
        || ' deleted_batch=' || l_batch_rows
        || ' ' || fmt_num(round(seconds_since(l_started), 3)) || 's'
    );
exception
    when others then
        i_log(l_proc_name, 0, 'failed ' || sqlerrm);
        rollback;
        gv_target_owner := null;
        gv_target_table := null;
        gv_data_slice := null;
        gv_batch_no := null;
        gv_batch_size := null;
        gv_batch_total := null;
        gv_commit_batch := true;
        gv_batches_ready := false;
        raise;
    end;
end initialize;

procedure capture_delta(
    p_source_table    varchar2,
    p_sql             varchar2,
    p_lookback_hours  number default null,
    p_owner           varchar2 default null
) is
    l_proc_name    varchar2(64) := get_proc_name('capture_delta');
    l_started      timestamp := systimestamp;
    l_source_owner varchar2(128);
    l_source_table varchar2(128);
    l_lookback     number;
    l_watermark    date;
    l_bound        date;
    l_insert_sql   clob;
    l_pk2          varchar2(64);
    l_pk3          varchar2(64);
    l_rows         number := 0;
    l_slice_rows   number := 0;
    l_slice_pk     number := 0;
    l_min          date;
    l_max          date;
begin
    assert_ready;

    l_source_owner := resolve_owner(p_owner);
    l_source_table := norm_ident(p_source_table, 'source_table');

    if p_sql is null then
        raise_application_error(-20006, 'capture sql is required');
    end if;

    if placeholder_count(p_sql, ':since') != 1 then
        raise_application_error(-20015, 'capture SQL must contain :since exactly once');
    end if;

    assert_relation(l_source_owner, l_source_table);

    l_lookback := coalesce(p_lookback_hours, gv_lookback_hours, 0);

    if l_lookback < 0 then
        raise_application_error(-20002, 'lookback_hours must be >= 0');
    end if;

    if gv_batches_ready then
        raise_application_error(-20013, 'capture_delta is closed after prepare_batches until finalize');
    end if;

    if unfinished_batches > 0 then
        raise_application_error(-20013, 'capture_delta is closed after prepare_batches until finalize');
    end if;

    l_watermark := get_watermark(l_source_owner, l_source_table);
    -- Date arithmetic keeps the bound as DATE. Hours are a fraction of a day.
    l_bound := l_watermark - l_lookback / 24;

    if not capture_has_col(p_sql, l_bound, 'pk_1')
       or not capture_has_col(p_sql, l_bound, 'watermark') then
        raise_application_error(
            -20020,
            'capture SQL must return pk_1 and watermark; pk_2 and pk_3 are optional'
        );
    end if;

    l_pk2 := case
                 when capture_has_col(p_sql, l_bound, 'pk_2') then 's.pk_2'
                 else 'cast(null as varchar2(255))'
             end;
    l_pk3 := case
                 when capture_has_col(p_sql, l_bound, 'pk_3') then 's.pk_3'
                 else 'cast(null as varchar2(255))'
             end;

    begin
    l_insert_sql := '
        begin
            insert into dwv_keys_tmp (
                source_owner,
                source_table,
                pk_1,
                pk_2,
                pk_3,
                watermark
            )
            select
                :source_owner,
                :source_table,
                s.pk_1,
                ' || l_pk2 || ',
                ' || l_pk3 || ',
                s.watermark
            from (' || p_sql || ') s;
            :cnt_out := sql%rowcount;
        end;';

    execute immediate l_insert_sql
        using in l_source_owner, in l_source_table, in l_bound, out l_rows;

    if gv_debug then
        select nvl(sum(cnt), 0),
               min(min_wm),
               max(max_wm),
               count(*)
        into l_slice_rows, l_min, l_max, l_slice_pk
        from (
            select count(*) cnt,
                   min(watermark) min_wm,
                   max(watermark) max_wm
            from dwv_keys_tmp
            where source_owner = l_source_owner
              and source_table = l_source_table
            group by pk_1, pk_2, pk_3
        );
    end if;

    i_log(
        l_proc_name,
        l_rows,
        fmt_col('source=' || l_source_owner || '.' || l_source_table, c_w_name)
        || fmt_col('stored=' || fmt_date(l_watermark), c_w_date)
        || fmt_col('lookback_hours=' || fmt_num(l_lookback), 20)
        || fmt_col('bound=' || fmt_date(l_bound), c_w_date)
        || fmt_col('inserted=' || l_rows, 20)
        || case
               when gv_debug then
                   fmt_col('slice_rows=' || l_slice_rows, 22)
                   || fmt_col('slice_pk=' || l_slice_pk, 20)
                   || fmt_col('min=' || fmt_date(l_min), c_w_date)
                   || fmt_col('max=' || fmt_date(l_max), c_w_date)
               else
                   null
           end
        || fmt_num(round(seconds_since(l_started), 3)) || 's'
    );
exception
    when others then
        i_log(
            l_proc_name,
            nvl(l_rows, 0),
            fmt_col('source=' || nvl(l_source_table, 'null'), c_w_name) || 'failed ' || sqlerrm
        );
        rollback;
        raise;
    end;
end capture_delta;

procedure prepare_batches(
    p_batch_size    number  default 5000,
    p_commit_batch  boolean default true
) is
    l_proc_name    varchar2(64) := get_proc_name('prepare_batches');
    l_started      timestamp := systimestamp;
    l_commit_batch boolean := true;
    l_batch_size   number := p_batch_size;
    l_assigned     number := 0;
    l_key_total    number := 0;
    l_left         number := 0;
    l_total        number := 0;
begin
    assert_ready;

    if p_commit_batch = false then
        l_commit_batch := false;
    end if;

    if l_batch_size is null or l_batch_size < 1 or l_batch_size != trunc(l_batch_size) then
        raise_application_error(-20003, 'batch_size must be a positive integer');
    end if;

    select count(*)
    into l_key_total
    from dwv_keys_tmp
    where rownum = 1;

    select count(*)
    into l_assigned
    from dwv_keys_tmp
    where batch_no is not null
      and rownum = 1;

    if l_assigned > 0 and gv_batch_size is not null and l_batch_size != gv_batch_size then
        raise_application_error(
            -20009,
            'batch_size cannot change while batches are in progress, current=' || gv_batch_size
        );
    end if;

    if l_assigned > 0 and gv_batch_size is not null and l_commit_batch != gv_commit_batch then
        raise_application_error(-20018, 'p_commit_batch cannot change while batches are in progress');
    end if;

    assert_no_open_batch;

    gv_commit_batch := l_commit_batch;
    gv_batches_ready := true;
    gv_batch_no := null;

    if l_key_total = 0 then
        i_log(
            l_proc_name,
            0,
            'no keys, nothing to apply ' || fmt_num(round(seconds_since(l_started), 3)) || 's'
        );
        return;
    end if;

    gv_batch_size := l_batch_size;

    begin
        if l_assigned = 0 then
            merge into dwv_keys_tmp t
            using (
                select pk_1,
                       pk_2,
                       pk_3,
                       ceil(row_number() over (
                           order by pk_1, pk_2 nulls first, pk_3 nulls first
                       ) / l_batch_size) as batch_no
                from (
                    select distinct pk_1, pk_2, pk_3
                    from dwv_keys_tmp
                )
            ) s
            on (t.pk_1 = s.pk_1
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
                || case when l_commit_batch then ' commit_batch' else ' no_commit' end
            );
        else
            i_log(
                l_proc_name,
                0,
                'batch numbers already assigned batch_size=' || gv_batch_size
                || case when l_commit_batch then ' commit_batch' else ' no_commit' end
            );
        end if;

        select nvl(max(batch_no), 0)
        into l_total
        from dwv_keys_tmp;

        gv_batch_total := l_total;
        l_left := unfinished_batches;

        if l_left = 0 then
            i_log(l_proc_name, 0, 'nothing left to apply batches=' || l_total);
            return;
        end if;
    exception
        when others then
            note_failure(l_proc_name, l_key_total, sqlerrm);
            raise;
    end;
end prepare_batches;

procedure load_batch_keys(p_batch_no number, p_keys out number) is
begin
    delete from dwv_batch_tmp;

    insert into dwv_batch_tmp (pk_1, pk_2, pk_3)
    select distinct pk_1, pk_2, pk_3
    from dwv_keys_tmp
    where batch_no = p_batch_no
      and batch_done = 0;

    p_keys := sql%rowcount;
end load_batch_keys;

function next_batch return boolean is
    l_proc_name varchar2(64) := get_proc_name('next_batch');
    l_keys      number := 0;
    l_next      number;
    l_total     number;
begin
    assert_ready;

    if not gv_batches_ready then
        raise_application_error(-20016, 'Call prepare_batches first');
    end if;

    assert_no_open_batch;

    begin
        select min(batch_no)
        into l_next
        from dwv_keys_tmp
        where batch_no is not null
          and batch_done = 0;

        if l_next is null then
            return false;
        end if;

        load_batch_keys(l_next, l_keys);

        if l_keys = 0 then
            raise_application_error(-20011, 'batch ' || l_next || ' has no keys');
        end if;

        gv_batch_no := l_next;
        l_total := gv_batch_total;

        i_log(
            l_proc_name,
            l_keys,
            fmt_col('batch ' || gv_batch_no || '/' || l_total, c_w_batch)
            || 'keys=' || l_keys || ' opened'
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
        update dwv_keys_tmp
        set batch_done = 1
        where batch_no = l_batch_no
          and batch_done = 0;

        if sql%rowcount = 0 then
            raise_application_error(-20012, 'batch ' || l_batch_no || ' was not marked done');
        end if;

        l_total := gv_batch_total;

        if gv_commit_batch then
            commit;
        else
            delete from dwv_batch_tmp;
        end if;

        gv_batch_no := null;

        i_log(
            l_proc_name,
            l_merged,
            fmt_col('batch ' || l_batch_no || '/' || l_total, c_w_batch)
            || 'merged=' || l_merged
            || case when gv_commit_batch then ' committed' else ' uncommitted' end
        );
    exception
        when others then
            note_failure(l_proc_name, l_merged, sqlerrm);
            raise;
    end;
end finish_batch;

procedure finalize is
    l_proc_name  varchar2(64) := get_proc_name('finalize');
    l_started    timestamp := systimestamp;
    l_all_pk     number := 0;
    l_left       number := 0;
    l_unassigned number := 0;
    l_moved      number := 0;
begin
    assert_ready;

    if gv_batches_ready then
        l_left := unfinished_batches;
        select count(*)
        into l_unassigned
        from dwv_keys_tmp
        where batch_no is null
          and rownum = 1;
    end if;

    if l_left > 0
       or l_unassigned > 0 then
        raise_application_error(
            -20005,
            'unfinished batches for ' || gv_target_owner || '.' || gv_target_table
            || ' (' || l_left || ' left). Watermark was not moved. '
            || 'Finish the remaining batches before calling finalize.'
        );
    end if;

    gv_batches_ready := false;

    merge into dwv_watermark t
    using (
        select gv_target_owner as target_owner,
               gv_target_table as target_table,
               gv_data_slice as data_slice,
               source_owner,
               source_table,
               max(watermark) as watermark
        from dwv_keys_tmp
        group by source_owner, source_table
    ) s
    on (t.target_owner = s.target_owner
        and t.target_table = s.target_table
        and t.data_slice = s.data_slice
        and t.source_owner = s.source_owner
        and t.source_table = s.source_table)
    when matched then
        update set t.watermark = s.watermark,
                   t.updated_at = sysdate
        where t.watermark < s.watermark
    when not matched then
        insert (
            target_owner, target_table, data_slice,
            source_owner, source_table, watermark, updated_at
        )
        values (
            s.target_owner, s.target_table, s.data_slice,
            s.source_owner, s.source_table, s.watermark, sysdate
        );

    l_moved := sql%rowcount;

    if gv_debug then
        select count(*)
        into l_all_pk
        from (
            select distinct pk_1, pk_2, pk_3
            from dwv_keys_tmp
        );
    end if;

    i_log(
        l_proc_name,
        l_moved,
        'moved=' || l_moved
        || case when gv_debug then ' distinct_pk=' || l_all_pk else null end
        || ' ' || fmt_num(round(seconds_since(l_started), 3)) || 's'
    );

    delete from dwv_batch_tmp;

    release_run_lock;
    gv_target_owner := null;
    gv_target_table := null;
    gv_data_slice := null;
    gv_lookback_hours := 0;
    gv_batch_no := null;
    gv_batch_size := null;
    gv_batch_total := null;
exception
    when others then
        i_log(l_proc_name, nvl(l_all_pk, 0), 'failed ' || sqlerrm);
        if sqlcode != -20005 then
            rollback;
        end if;
        raise;
end finalize;

end pkg_dwv;
