# Demo

Small scripts to run dpl against a real target table, then against a larger one.

Deploy the library first: [Oracle](../lib/oracle/deploy.md) or [PostgreSQL](../lib/postgres/deploy.md).

The interesting file is `run.sql`. It is the incremental load: capture changed keys from three sources, refresh those keys, move the watermark. The other files only create tables and data.

## Oracle

```text
cd demo/oracle
sqlplus user/password@//host:1521/service
```

```sql
@tables.sql
@seed.sql
@run.sql
@check.sql
```

That loads three customers. `pkg_dpl` prints a timing line for each step.

Change one source row and run again. Only that customer is captured:

```sql
update orders set updated_at = sysdate where id = 101;
commit;
@run.sql
@check.sql
```

### Volume

```sql
@tables.sql
@seed_volume.sql
@run.sql
@check.sql
```

`seed_volume.sql` loads 100,000 customers, 1,000,000 orders and 30 items each (30,000,000 `order_items`), writes that load into `dpl_watermark`, then plants a 7% delta. `run.sql` therefore captures only the delta. Edit the constants at the top of `seed_volume.sql` to change the size.

With the docker stack from `tests/docker/docker-compose.yml`:

```text
sqlplus test/test_pass@//localhost:1522/FREEPDB1
```

## PostgreSQL

Put the install schema on `search_path` first. After `lib/postgres/deploy.sql` that schema is `lib` unless you passed `dpl_schema`.

```text
cd demo/postgres
psql "postgresql://user:password@localhost:5432/db"
```

```sql
set search_path to lib, public;
\i tables.sql
\i seed.sql
\i run.sql
\i check.sql
```

Change one source row and run again:

```sql
update orders set updated_at = clock_timestamp() where id = 101;
\i run.sql
\i check.sql
```

### Volume

```sql
\i tables.sql
\i seed_volume.sql
\i run.sql
\i check.sql
```

Same default size as Oracle. Edit the constants at the top of `seed_volume.sql`.

With the docker stack:

```text
psql "postgresql://test_user:test_pass@localhost:5434/test_db"
```
