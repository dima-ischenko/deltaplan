-- Install into an existing schema.
-- From the repository root:
--   psql -v ON_ERROR_STOP=1 -f lib/postgres/deploy.sql
--   psql -v ON_ERROR_STOP=1 -v dpl_schema=analytics -f lib/postgres/deploy.sql
-- psql resolves \i against the working directory.
\i lib/postgres/_install_schema.sql
\i lib/postgres/deploy_structure.sql
\i lib/postgres/deploy_code.sql
