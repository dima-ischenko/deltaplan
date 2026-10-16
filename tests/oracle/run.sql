-- Run the checks. tests/oracle/run.sh deploys pkg_dwa first from lib/oracle.
-- From the repository root:
-- sqlplus user/password@//host:1521/service @tests/oracle/run.sql

whenever sqlerror exit sql.sqlcode
set serveroutput on size unlimited
set define off
set feedback off
set verify off

begin execute immediate 'drop package pkg_dwa_test'; exception when others then if sqlcode != -4043 then raise; end if; end;
/
begin execute immediate 'drop package pkg_dwa_test'; exception when others then if sqlcode != -4043 then raise; end if; end;
/

@tests/oracle/helpers/tables.sql
@tests/oracle/helpers/pkg_dwa_test.sql

declare
    l_errors number;
begin
    select count(*)
    into l_errors
    from user_errors
    where name in ('PKG_DWA', 'PKG_DWA_TEST');

    if l_errors > 0 then
        for r in (
            select name, line, position, text
            from user_errors
            where name in ('PKG_DWA', 'PKG_DWA_TEST')
            order by name, sequence
        ) loop
            dbms_output.put_line(
                r.name || ' ' || r.line || '/' || r.position || ': ' || r.text
            );
        end loop;
        raise_application_error(-20000, 'dwa did not compile, errors=' || l_errors);
    end if;
end;
/

@tests/oracle/cases/static_without_batches.sql
@tests/oracle/cases/lookback_window.sql
@tests/oracle/cases/static_batches.sql
@tests/oracle/cases/same_result.sql
@tests/oracle/cases/rerun_after_failed_batch.sql
@tests/oracle/cases/batch_guards.sql
@tests/oracle/cases/debug_and_log.sql
@tests/oracle/cases/one_pk_one_batch.sql
@tests/oracle/cases/rollback_without_commit.sql
@tests/oracle/cases/volume.sql

begin
    dbms_output.put_line('pkg_dwa_test: passed');
end;
/

@tests/oracle/helpers/metrics_tables.sql
@tests/oracle/helpers/run_metrics.sql
@tests/oracle/cases/metrics_same_result.sql
@tests/oracle/cases/metrics_silent_dml.sql

delete from dwa_watermark
where target_table = 'customer_metrics';

@demo/oracle/tables.sql
@demo/oracle/seed.sql
@demo/oracle/run.sql
@demo/oracle/check.sql

declare
    l_metrics number;
    l_wm      number;
begin
    select count(*) into l_metrics from customer_metrics;
    select count(*)
    into l_wm
    from dwa_watermark
    where target_table = 'customer_metrics'
      and data_slice = 'all';

    if l_metrics != 3 then
        raise_application_error(-20000, 'demo metrics=' || l_metrics || ', expected 3');
    end if;
    if l_wm != 3 then
        raise_application_error(-20000, 'demo watermarks=' || l_wm || ', expected 3');
    end if;

    dbms_output.put_line('demo: passed');
end;
/
exit
