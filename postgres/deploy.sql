-- Install into an existing schema.
--   psql -v ON_ERROR_STOP=1 -f postgres/deploy.sql
--   psql -v ON_ERROR_STOP=1 -v dpl_schema=analytics -f postgres/deploy.sql
-- psql resolves \ir against this file's directory.
\ir _install_schema.sql
\ir deploy_structure.sql
\ir deploy_code.sql
