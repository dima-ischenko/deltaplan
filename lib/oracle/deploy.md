# Deploy on Oracle

From the repository root:

```bash
sqlplus user/password@//host:1521/service @lib/oracle/deploy.sql
sqlplus user/password@//host:1521/service @lib/oracle/rollback.sql
```

`deploy.sql` creates `dwv_watermark`, the session key tables, and `pkg_dwv` in the calculating user's schema. `rollback.sql` removes them. Both are safe when objects are absent.

`initialize` uses `DBMS_LOCK`. As a DBA, once per schema:

```bash
sqlplus sys/password@//host:1521/service as sysdba @lib/oracle/grant_lock.sql SCHEMA
```

How to call the package: [README.md](README.md).
