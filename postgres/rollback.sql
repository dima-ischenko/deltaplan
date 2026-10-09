-- Remove deltaplan from this database. Safe when objects are absent.
-- Code first, then structure, the reverse of deploy.sql.
-- psql resolves \ir against this file's directory.
\ir rollback_code.sql
\ir rollback_structure.sql
