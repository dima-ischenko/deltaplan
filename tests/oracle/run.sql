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
@@cases/resume_same_batch.sql
@@cases/batch_guards.sql
@@cases/one_pk_one_batch.sql
@@cases/rollback_without_commit.sql
@@cases/volume.sql

begin
    dbms_output.put_line('pkg_dpl_test: passed');
end;
/

@@demo/pkg_dpl_demo_s.sql
/
@@demo/pkg_dpl_demo_b.sql
/

declare
    l_errors number;
begin
    select count(*)
    into l_errors
    from user_errors
    where name = 'PKG_DPL_DEMO';

    if l_errors > 0 then
        raise_application_error(-20000, 'pkg_dpl_demo did not compile, errors=' || l_errors);
    end if;
end;
/

@@demo/seed_customer_metrics.sql
@@demo/example_customer_metrics.sql
@@demo/check_customer_metrics.sql
exit
