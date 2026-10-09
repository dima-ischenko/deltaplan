-- Install deltaplan into the current schema.
-- The calculating user must own these objects: the key tables are
-- global temporary tables, and the package keeps its state in the session.

whenever sqlerror exit sql.sqlcode

@@deltaplan_watermark.sql
@@deltaplan_keys_tmp.sql
@@deltaplan_batch_tmp.sql
@@pkg_deltaplan_s.sql
/
@@pkg_deltaplan_b.sql
/
