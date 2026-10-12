-- Remove dpl from the current schema. Safe when objects are absent.
-- Code first, then structure, the reverse of deploy.sql.
-- Start from lib/oracle/.

whenever sqlerror exit sql.sqlcode

@@rollback_code.sql
@@rollback_structure.sql
