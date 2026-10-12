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

-- The test package names these tables in static SQL, so they must exist at compile time.
-- setup drops and recreates them when the suite runs.
begin execute immediate 'drop table inc_test_seen purge'; exception when others then if sqlcode != -942 then raise; end if; end;
/
begin execute immediate 'drop table inc_test_expect purge'; exception when others then if sqlcode != -942 then raise; end if; end;
/
begin execute immediate 'drop table inc_test_tgt purge'; exception when others then if sqlcode != -942 then raise; end if; end;
/
begin execute immediate 'drop table inc_test_b purge'; exception when others then if sqlcode != -942 then raise; end if; end;
/
begin execute immediate 'drop table inc_test_a purge'; exception when others then if sqlcode != -942 then raise; end if; end;
/
create table inc_test_a (
    id         varchar2(10) not null,
    amount     number not null,
    updated_at date not null,
    constraint pk_inc_test_a primary key (id)
);
create table inc_test_b (
    id         varchar2(10) not null,
    amount     number not null,
    updated_at date not null,
    constraint pk_inc_test_b primary key (id)
);
create table inc_test_tgt (
    id     varchar2(10) not null,
    amount number not null,
    touch  number not null,
    constraint pk_inc_test_tgt primary key (id)
);
create table inc_test_expect (
    id     varchar2(10) not null,
    amount number not null,
    touch  number not null,
    constraint pk_inc_test_expect primary key (id)
);
create table inc_test_seen (
    batch_no number not null,
    id       varchar2(10) not null
);

@@pkg_dpl_test.sql

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

exec pkg_dpl_test.run
exit
