# Deploy on PostgreSQL

The same scripts deploy on Greenplum 7. Objects go into the current schema, or into `dwa_schema` when you pass it.

From the repository root:

```bash
psql "postgresql://user:password@localhost:5432/db" -v ON_ERROR_STOP=1 -f lib/postgres/deploy.sql
psql "postgresql://user:password@localhost:5432/db" -v ON_ERROR_STOP=1 -v dwa_schema=analytics -f lib/postgres/deploy.sql
```

Put that schema on `search_path` before calling the functions. `initialize` creates the session temp tables.

```bash
psql "postgresql://user:password@localhost:5432/db" -v ON_ERROR_STOP=1 -v dwa_schema=analytics -f lib/postgres/rollback.sql
```

`rollback.sql` removes the functions and `dwa_watermark` from that schema. Both files are safe when objects are absent.

How to call the functions: [README.md](README.md).
