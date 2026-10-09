-- Deploy deltaplan into the current schema.
-- The calculating user must own these objects: the key tables are
-- global temporary tables, and the package keeps its state in the session.
-- SQL*Plus resolves @@ against the working directory, so run this from oracle/.

whenever sqlerror exit sql.sqlcode

@@deploy_structure.sql
@@deploy_code.sql
