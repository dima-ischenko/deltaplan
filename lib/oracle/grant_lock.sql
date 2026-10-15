-- Run as SYS. initialize uses DBMS_LOCK for the (owner, target, slice) run lock.
-- sqlplus sys/password@//host:1521/service as sysdba @lib/oracle/grant_lock.sql SCHEMA
whenever sqlerror exit sql.sqlcode
set verify off
grant execute on sys.dbms_lock to &1;
exit
