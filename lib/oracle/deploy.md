# Deploy on Oracle

Start from the repository root. Nested scripts use `@lib/oracle/...`, resolved from the working directory.

```bash
sqlplus user/password@//host:1521/service @lib/oracle/deploy.sql
```

`deploy.sql` runs `deploy_structure.sql` then `deploy_code.sql`. This creates `dpl_watermark`, the two global temporary tables, and `pkg_dpl`.

```bash
sqlplus user/password@//host:1521/service @lib/oracle/rollback.sql
```

`rollback.sql` is the reverse: `rollback_code.sql` then `rollback_structure.sql`. Both files are safe when objects are absent.

How to call the package after deploy: [README.md](README.md).

## Layout

Tables live in `ddl_dml/`, the package in `packages/`. After deploy, the playground is [`demo/oracle`](../../demo/README.md).

The calculating user must own the objects: the key tables are global temporary tables, and the package keeps its state in the session.
