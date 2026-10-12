-- Deploy dpl into the current schema.
-- The calculating user must own these objects: the key tables are
-- global temporary tables, and the package keeps its state in the session.
-- Start from lib/oracle/: @@ddl_dml/file.sql is resolved from the working
-- directory, not from this file.

whenever sqlerror exit sql.sqlcode

@@deploy_structure.sql
@@deploy_code.sql
