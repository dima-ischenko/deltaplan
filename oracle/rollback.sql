-- Remove deltaplan from the current schema. Safe when objects are absent.
-- Code first, then structure, the reverse of deploy.sql.
-- SQL*Plus resolves @@ against the working directory, so run this from oracle/.

whenever sqlerror exit sql.sqlcode

@@rollback_code.sql
@@rollback_structure.sql
