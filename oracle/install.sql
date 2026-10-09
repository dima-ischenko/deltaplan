-- Install deltaplan into the current schema.
-- The calculating user must own these objects: the key tables are
-- global temporary tables, and the package keeps its state in the session.

whenever sqlerror exit sql.sqlcode

@@deltaplan_watermark.sql
@@deltaplan_keys.sql
@@deltaplan_batch.sql
@@pkg_deltaplan_s.sql
/
@@pkg_deltaplan_b.sql
/
