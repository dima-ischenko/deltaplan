-- Rebuild deltaplan in the current schema and run the checks.
-- sqlplus user/password@//host:1521/service @tests/oracle/run.sql

whenever sqlerror exit sql.sqlcode
set serveroutput on size unlimited
set define off
set feedback off
set verify off

begin execute immediate 'drop package pkg_deltaplan_test'; exception when others then if sqlcode != -4043 then raise; end if; end;
/
begin execute immediate 'drop package pkg_deltaplan'; exception when others then if sqlcode != -4043 then raise; end if; end;
/
begin execute immediate 'drop table deltaplan_batch_tmp purge'; exception when others then if sqlcode != -942 then raise; end if; end;
/
begin execute immediate 'drop table deltaplan_batch purge'; exception when others then if sqlcode != -942 then raise; end if; end;
/
begin execute immediate 'drop table deltaplan_keys_tmp purge'; exception when others then if sqlcode != -942 then raise; end if; end;
/
begin execute immediate 'drop table deltaplan_keys purge'; exception when others then if sqlcode != -942 then raise; end if; end;
/
begin execute immediate 'drop table deltaplan_key purge'; exception when others then if sqlcode != -942 then raise; end if; end;
/
begin execute immediate 'drop table deltaplan_watermark purge'; exception when others then if sqlcode != -942 then raise; end if; end;
/
begin execute immediate 'drop table deltaplan_mark purge'; exception when others then if sqlcode != -942 then raise; end if; end;
/

@@../../oracle/ddl_dml/deltaplan_watermark.sql
@@../../oracle/ddl_dml/deltaplan_keys_tmp.sql
@@../../oracle/ddl_dml/deltaplan_batch_tmp.sql
@@../../oracle/packages/pkg_deltaplan_s.sql
/
@@../../oracle/packages/pkg_deltaplan_b.sql
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

@@pkg_deltaplan_test.sql

declare
    l_errors number;
begin
    select count(*)
    into l_errors
    from user_errors
    where name in ('PKG_DELTAPLAN', 'PKG_DELTAPLAN_TEST');

    if l_errors > 0 then
        raise_application_error(-20000, 'deltaplan did not compile, errors=' || l_errors);
    end if;
end;
/

set linesize 32767
set pagesize 0
set heading off
begin
    ut.run('pkg_deltaplan_test');
end;
/
exit
