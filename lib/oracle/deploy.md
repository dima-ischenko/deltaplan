# Deploy on Oracle

From the repository root:

```bash
sqlplus user/password@//host:1521/service @lib/oracle/deploy.sql
sqlplus user/password@//host:1521/service @lib/oracle/rollback.sql
```

`deploy.sql` creates `dpl_watermark`, the session key tables, and `pkg_dpl` in the calculating user's schema. `rollback.sql` removes them. Both are safe when objects are absent.

How to call the package: [README.md](README.md).
