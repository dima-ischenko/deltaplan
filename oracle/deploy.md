# Deploy on Oracle

```bash
cd oracle
sqlplus user/password@//host:1521/service @deploy.sql
```

`deploy.sql` runs `deploy_structure.sql` then `deploy_code.sql`. This creates `deltaplan_watermark`, the two global temporary tables, and `pkg_deltaplan`.

```bash
cd oracle
sqlplus user/password@//host:1521/service @rollback.sql
```

`rollback.sql` is the reverse: `rollback_code.sql` then `rollback_structure.sql`. Both files are safe when objects are absent.

How to call the package after deploy: [README.md](README.md).

## Layout

Tables live in `ddl_dml/`, the package in `packages/`, as in `rpd_data/lib` and `dwh_ato/lib`. SQL\*Plus resolves `@@` against the working directory, so run the scripts from `oracle/`.

The calculating user must own the objects: the key tables are global temporary tables, and the package keeps its state in the session.
