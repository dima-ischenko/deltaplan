-- Deploy dpl into the current schema.
-- The calculating user must own these objects: the key tables are
-- global temporary tables, and the package keeps its state in the session.
-- Start from the repository root: @lib/oracle/... is resolved from the
-- working directory.

whenever sqlerror exit sql.sqlcode

@lib/oracle/deploy_structure.sql
@lib/oracle/deploy_code.sql
