-- Rebuild dpl in the current schema and run the checks.
-- sqlplus user/password@//host:1521/service @tests/oracle/run.sql

whenever sqlerror exit sql.sqlcode
set serveroutput on size unlimited
set define off
set feedback off
set verify off

begin execute immediate 'drop package pkg_dpl_test'; exception when others then if sqlcode != -4043 then raise; end if; end;
/
@@../../lib/oracle/rollback_code.sql
@@../../lib/oracle/rollback_structure.sql
@@../../lib/oracle/ddl_dml/dpl_watermark.sql
@@../../lib/oracle/ddl_dml/dpl_keys_tmp.sql
@@../../lib/oracle/ddl_dml/dpl_batch_tmp.sql
@@../../lib/oracle/packages/pkg_dpl_s.sql
/
@@../../lib/oracle/packages/pkg_dpl_b.sql
/

@@helpers/tables.sql
@@helpers/pkg_dpl_test.sql

declare
    l_errors number;
begin
    select count(*)
    into l_errors
    from user_errors
    where name in ('PKG_DPL', 'PKG_DPL_TEST');

    if l_errors > 0 then
        raise_application_error(-20000, 'dpl did not compile, errors=' || l_errors);
    end if;
end;
/

@@cases/static_without_batches.sql
@@cases/lookback_window.sql
@@cases/static_batches.sql
@@cases/same_result.sql
@@cases/rerun_after_failed_batch.sql
@@cases/batch_guards.sql
@@cases/one_pk_one_batch.sql
@@cases/rollback_without_commit.sql
@@cases/volume.sql

begin
    dbms_output.put_line('pkg_dpl_test: passed');
end;
/

@@../../demo/oracle/tables.sql
@@../../demo/oracle/seed.sql
@@../../demo/oracle/run.sql
@@../../demo/oracle/check.sql

declare
    l_metrics number;
    l_wm      number;
begin
    select count(*) into l_metrics from customer_metrics;
    select count(*)
    into l_wm
    from dpl_watermark
    where target_table = 'customer_metrics'
      and data_segment = 'all';

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
