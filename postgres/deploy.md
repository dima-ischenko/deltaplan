# Deploy on PostgreSQL

The same scripts deploy on Greenplum 7.

```bash
psql "postgresql://user:password@localhost:5432/db" -f postgres/deploy.sql
```

`deploy.sql` runs `deploy_structure.sql` then `deploy_code.sql`. This creates schema `deltaplan`, the functions, and `public.deltaplan_watermark`. `initialize` creates the temporary tables for the session.

```bash
psql "postgresql://user:password@localhost:5432/db" -f postgres/rollback.sql
```

`rollback.sql` is the reverse: `rollback_code.sql` then `rollback_structure.sql`. Both files are safe when objects are absent.

How to call the functions after deploy: [README.md](README.md).

## Layout

Tables live in `ddl_dml/`, routines in `functions/`. `psql` resolves `\ir` against the file that contains it, so these can be run from any working directory.

On Greenplum, `deltaplan_watermark` is `DISTRIBUTED BY (target_table)`, and the temporary key tables are `DISTRIBUTED BY (pk_1)`.
