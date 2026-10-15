-- Remove dwv from the current schema. Safe when objects are absent.
-- Code first, then structure, the reverse of deploy.sql.
-- Start from the repository root.

whenever sqlerror exit sql.sqlcode

@lib/oracle/rollback_code.sql
@lib/oracle/rollback_structure.sql
