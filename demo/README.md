# Demo

Scripts that load `customer_metrics` from three sources. Deploy first: [Oracle](../lib/oracle/deploy.md) or [PostgreSQL](../lib/postgres/deploy.md).

`run.sql` is the incremental load. Seed scripts load source rows only; `run.sql` writes `dwa_watermark` after it computes `customer_metrics`. Start from the repository root.

## Oracle

```text
sqlplus user/password@//host:1521/service
```

```sql
@demo/oracle/tables.sql
@demo/oracle/seed.sql
@demo/oracle/run.sql
@demo/oracle/check.sql
```

Change one source row and run again:

```sql
update orders set updated_at = sysdate where id = 101;
commit;
@demo/oracle/run.sql
@demo/oracle/check.sql
```

### Volume

```sql
@demo/oracle/tables.sql
@demo/oracle/seed_volume.sql
@demo/oracle/run.sql
@demo/oracle/seed_delta.sql
@demo/oracle/run.sql
@demo/oracle/check.sql
```

Defaults are at the top of `seed_volume.sql` and `seed_delta.sql` (`c_delta_mode`: `update`, `insert`, or `mix`). Run `seed_delta.sql` again to plant another slice.

Docker stack from `tests/docker/docker-compose.yml`:

```text
sqlplus test/test_pass@//localhost:1522/FREEPDB1
```

## PostgreSQL

Put the install schema on `search_path`. After `lib/postgres/deploy.sql` that schema is `lib` unless you passed `dwa_schema`.

```text
psql "postgresql://user:password@localhost:5432/db"
```

```sql
set search_path to lib, public;
\i demo/postgres/tables.sql
\i demo/postgres/seed.sql
\i demo/postgres/run.sql
\i demo/postgres/check.sql
```

Change one source row and run again:

```sql
update orders set updated_at = clock_timestamp() where id = 101;
\i demo/postgres/run.sql
\i demo/postgres/check.sql
```

### Volume

```sql
\i demo/postgres/tables.sql
\i demo/postgres/seed_volume.sql
\i demo/postgres/run.sql
\i demo/postgres/seed_delta.sql
\i demo/postgres/run.sql
\i demo/postgres/check.sql
```

Docker stack:

```text
psql "postgresql://test_user:test_pass@localhost:5434/test_db"
```
