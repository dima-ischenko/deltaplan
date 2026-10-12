-- Remove this install from the selected schema. Safe when objects are absent.
-- Code first, then structure, the reverse of deploy.sql.
-- From the repository root:
--   psql -v ON_ERROR_STOP=1 -v dpl_schema=analytics -f lib/postgres/rollback.sql
-- psql resolves \i against the working directory.
\i lib/postgres/_install_schema.sql
\i lib/postgres/rollback_code.sql
\i lib/postgres/rollback_structure.sql
