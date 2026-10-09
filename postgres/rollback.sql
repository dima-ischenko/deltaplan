-- Remove this install from the selected schema. Safe when objects are absent.
-- Code first, then structure, the reverse of deploy.sql.
--   psql -v ON_ERROR_STOP=1 -v dpl_schema=analytics -f postgres/rollback.sql
-- psql resolves \ir against this file's directory.
\ir _install_schema.sql
\ir rollback_code.sql
\ir rollback_structure.sql
