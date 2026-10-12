# Deploy on Oracle

```bash
cd lib/oracle
sqlplus user/password@//host:1521/service @deploy.sql
```

`deploy.sql` runs `deploy_structure.sql` then `deploy_code.sql`. This creates `dpl_watermark`, the two global temporary tables, and `pkg_dpl`.

```bash
cd lib/oracle
sqlplus user/password@//host:1521/service @rollback.sql
```

`rollback.sql` is the reverse: `rollback_code.sql` then `rollback_structure.sql`. Both files are safe when objects are absent.

How to call the package after deploy: [README.md](README.md).

## Layout

Tables live in `ddl_dml/`, the package in `packages/`, as in `rpd_data/lib` and `dwh_ato/lib`. After deploy, the playground is [`demo/oracle`](../../demo/README.md). Start `@deploy.sql` from `lib/oracle/`. `@@ddl_dml/file.sql` is resolved from the working directory, so the suite runs rollback and deploy from that directory before the checks.

The calculating user must own the objects: the key tables are global temporary tables, and the package keeps its state in the session.
