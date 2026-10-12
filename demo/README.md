# Demo

Small scripts to run dpl against a real target table, then against a larger one.

Deploy the library first: [Oracle](../lib/oracle/deploy.md) or [PostgreSQL](../lib/postgres/deploy.md).

The interesting file is `run.sql`. It is the incremental load: capture changed keys from three sources, refresh those keys, move the watermark. The other files only create tables and data.

Start from the repository root. Nested scripts use `@demo/oracle/...` and `\i demo/postgres/...`.

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

That loads three customers. `pkg_dpl` prints a timing line for each step.

Change one source row and run again. Only that customer is captured:

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
@demo/oracle/seed_delta.sql
@demo/oracle/run.sql
@demo/oracle/check.sql
```

`seed_volume.sql` loads 100,000 customers, 1,000,000 orders and 30 items each (30,000,000 `order_items`) and writes the load time into `dpl_watermark`. The source rows stay on the base timestamp, so that watermark sits after all of them. `seed_delta.sql` then plants a 7% delta (half updates, half new customers) without reloading the volume. Run `seed_delta.sql` again to plant another slice. `run.sql` captures only rows newer than the watermark. Edit the constants at the top of `seed_volume.sql` and `seed_delta.sql` to change the size.

With the docker stack from `tests/docker/docker-compose.yml`:

```text
sqlplus test/test_pass@//localhost:1522/FREEPDB1
```

## PostgreSQL

Put the install schema on `search_path` first. After `lib/postgres/deploy.sql` that schema is `lib` unless you passed `dpl_schema`.

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
\i demo/postgres/seed_delta.sql
\i demo/postgres/run.sql
\i demo/postgres/check.sql
```

Same split as Oracle: `seed_volume.sql` loads the base, `seed_delta.sql` plants the 7% delta and can be run again on its own. Edit the constants at the top of those files.

With the docker stack:

```text
psql "postgresql://test_user:test_pass@localhost:5434/test_db"
```
