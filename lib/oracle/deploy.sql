-- Deploy dpl into the current schema.
-- The calculating user must own these objects: the key tables are
-- global temporary tables, and the package keeps its state in the session.
-- From the command line, start this file from lib/oracle/ (@ is the working
-- directory). Nested @@ paths are resolved next to each script, so this file
-- can also be called with @@ from tests/oracle/run.sql.

whenever sqlerror exit sql.sqlcode

@@deploy_structure.sql
@@deploy_code.sql
