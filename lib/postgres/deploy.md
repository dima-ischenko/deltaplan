# Deploy on PostgreSQL

The same scripts deploy on Greenplum 7. Objects are created in an existing schema: the session's current schema, or the schema passed as `dpl_schema`.

Start from the repository root. Nested scripts use `\i lib/postgres/...`, resolved from the working directory.

```bash
psql "postgresql://user:password@localhost:5432/db" -v ON_ERROR_STOP=1 -f lib/postgres/deploy.sql
psql "postgresql://user:password@localhost:5432/db" -v ON_ERROR_STOP=1 -v dpl_schema=analytics -f lib/postgres/deploy.sql
```

`deploy.sql` runs `deploy_structure.sql` then `deploy_code.sql`. This creates the functions and `dpl_watermark` in that schema. `initialize` creates the temporary tables for the session. Put the schema on `search_path` before calling the functions.

```bash
psql "postgresql://user:password@localhost:5432/db" -v ON_ERROR_STOP=1 -v dpl_schema=analytics -f lib/postgres/rollback.sql
```

`rollback.sql` is the reverse: `rollback_code.sql` then `rollback_structure.sql`. It removes the functions and `dpl_watermark` from that schema. When the selected schema is not `deltaplan`, it also drops schema `deltaplan` left by an earlier install. Both files are safe when objects are absent.

How to call the functions after deploy: [README.md](README.md).

## Layout

Tables live in `ddl_dml/`, routines in `functions/`. After deploy, the playground is [`demo/postgres`](../../demo/README.md).

On Greenplum, `dpl_watermark` is `DISTRIBUTED BY (target_table)`, and the temporary key tables are `DISTRIBUTED BY (pk_1)`.
