-- Remove dpl from the current schema. Safe when objects are absent.
-- Code first, then structure, the reverse of deploy.sql.
-- From the command line, start this file from lib/oracle/. Nested @@ paths
-- are resolved next to each script, so this file can also be called with @@
-- from tests/oracle/run.sql.

whenever sqlerror exit sql.sqlcode

@@rollback_code.sql
@@rollback_structure.sql
