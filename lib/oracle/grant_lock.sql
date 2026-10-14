-- Run as a DBA. initialize uses DBMS_LOCK for the (target, segment) run lock.
-- sqlplus system/password@//host:1521/service @lib/oracle/grant_lock.sql SCHEMA
whenever sqlerror exit sql.sqlcode
set verify off
grant execute on sys.dbms_lock to &1;
exit
