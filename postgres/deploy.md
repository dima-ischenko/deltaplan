# Deploy on PostgreSQL

The same scripts deploy on Greenplum 7. Tables live in `ddl_dml/`, routines in `functions/`. `psql` resolves `\ir` against the file that contains it, so these can be run from any working directory.

## Deploy

```bash
psql "postgresql://user:password@localhost:5432/db" -f postgres/deploy.sql
```

`deploy.sql` runs `deploy_structure.sql` then `deploy_code.sql`. This creates schema `deltaplan`, the functions, and `public.deltaplan_watermark`. `initialize` creates the temporary tables for the session.

## Rollback

```bash
psql "postgresql://user:password@localhost:5432/db" -f postgres/rollback.sql
```

`rollback.sql` is the reverse: `rollback_code.sql` then `rollback_structure.sql`. Both files are safe when objects are absent.

## Greenplum

The functions do not commit, so they run on Greenplum releases that forbid a commit inside a function. `deltaplan_watermark` is `DISTRIBUTED BY (target_table)`, and the temporary key tables are `DISTRIBUTED BY (pk_1)`.
