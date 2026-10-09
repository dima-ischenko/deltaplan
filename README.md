# deltaplan

Deltaplan refreshes a mart incrementally by primary key. A capture statement finds rows that moved past the watermark, the calculation applies those keys, and `finalize` stores the new watermark. It does not move the watermark backwards, and it does not move it while a batch is still open.

The calculation itself is ordinary SQL that you write. Batches are optional.

## Layout

| Path | What it is |
| --- | --- |
| `oracle/` | Tables and the `pkg_deltaplan` package |
| `postgres/` | The same contract as functions and procedures in schema `deltaplan` |
| `examples/oracle/` | A customer-metrics session, and a volume seeder that is not part of the tests |
| `examples/postgres/` | The same session in PostgreSQL |
| `tests/oracle/` | PL/SQL checks, driven by SQL\*Plus |
| `tests/postgres/` | The same checks, driven by `psql` |
| `tests/docker/` | Oracle and PostgreSQL for a machine that does not already have them |

The three tables have the same names on both engines: `deltaplan_watermark` (the stored high-water mark), `deltaplan_keys` (every captured key for this run), and `deltaplan_batch` (the keys of the batch that is open). `deltaplan_keyset` is the distinct business key. `deltaplan_keys` keeps one row per source so each source can advance its own watermark. Join `deltaplan_keyset` or `deltaplan_batch` into an aggregate. Joining `deltaplan_keys` counts a customer once per source.

Column order is the same on both engines. `deltaplan_watermark` is `target_table`, `data_segment`, `source_table`, then `watermark`, then `updated_at`. `deltaplan_keys` starts with those three columns, then `pk_1`, `pk_2`, `pk_3` in the same order as `deltaplan_batch`, then the source `watermark` of that key, then `batch_no` and `batch_done`. A capture statement projects `pk_1`, `pk_2`, `pk_3`, `watermark` and filters with `:since`.

## Install on Oracle

From `oracle/`, because SQL\*Plus resolves `@@` against the working directory:

```bash
cd oracle
sqlplus user/password@//host:1521/service @install.sql
```

That creates `deltaplan_watermark`, the two global temporary tables, and `pkg_deltaplan`. The calculating user has to own them. The package keeps its position in the session, so a rollback does not forget which batch was open.

## Install on PostgreSQL and Greenplum

PostgreSQL has no packages. The routines live in schema `deltaplan`, and `initialize` creates the temporary tables for the session. The same file installs on Greenplum 7: that is the first Greenplum release whose procedures can commit, and it has no `MERGE`.

```bash
psql "postgresql://user:password@localhost:5432/db" -f postgres/deltaplan.sql
```

`deltaplan_watermark` is created in `public`. The engine needs PostgreSQL 11 or newer, because `prepare_batches` and `finish_batch` commit. The watermark is written with `INSERT ... ON CONFLICT`. On Greenplum that table is `DISTRIBUTED BY (target_table)`, which is what makes the primary key and the upsert legal, and the temporary key tables are `DISTRIBUTED BY (pk_1)`.

The tests and `examples/postgres/example_customer_metrics.sql` load the target with `UPDATE` and `INSERT`. That is the statement to use on Greenplum. On PostgreSQL 15 or newer the same load can be one `MERGE`. The suite was run on PostgreSQL 15.4; a Greenplum cluster was not started here.

If the transaction that called `initialize` is rolled back, the temporary tables go with it. Call `initialize` again.

## A run without batches

The capture statement contains `:since` once. That placeholder is already the stored watermark minus the lookback. The predicate stays strict: `value > :since`. When no watermark is stored, `:since` is the minimum timestamp (`-infinity` on PostgreSQL, 1 January 4712 BCE on Oracle) and lookback is not subtracted. `finalize` never moves a stored watermark backwards.

Hard deletes are not supported. Capture reads a row that is still in the source. A `DELETE` leaves nothing whose watermark can move, and lookback does not bring that row back. A mart key is refreshed only when some surviving row moves past `:since` and the capture statement returns that key.

```sql
begin
    pkg_deltaplan.initialize('customer_metrics', 'all', 2);
    pkg_deltaplan.capture_delta('orders', q'[
        select customer_id as pk_1,
               null as pk_2,
               null as pk_3,
               max(updated_at) as watermark
        from orders
        where updated_at > :since
        group by customer_id
    ]');
    -- merge or update, reading deltaplan_keyset
    -- where target_table = pkg_deltaplan.get_target_table
    --   and data_segment = pkg_deltaplan.get_data_segment
    -- only captured keys are visible; a hard-deleted source row is not one of them
    pkg_deltaplan.finalize;
end;
```

On PostgreSQL the same steps are `call deltaplan.initialize(...)`, `call deltaplan.capture_delta(...)`, your statement, and `call deltaplan.finalize()`. Read `deltaplan_keyset` with `deltaplan.get_target_table()` and `deltaplan.get_data_segment()`.

## A run in batches

`prepare_batches` numbers the keys. With `p_commit` true it commits them first, then each `finish_batch` commits its own batch. The same session can resume at the unfinished batch after a rollback. The key tables are temporary, so a new session does not see them. `finalize` refuses to move the watermark until every batch is done.

```sql
pkg_deltaplan.prepare_batches(5000);
while pkg_deltaplan.next_batch loop
    -- one merge, insert, update or delete against deltaplan_batch
    pkg_deltaplan.finish_batch;   -- call it immediately after that statement
end loop;
pkg_deltaplan.finalize;
```

On PostgreSQL, `next_batch` is a function and the others are procedures:

```sql
call deltaplan.prepare_batches(5000);
while deltaplan.next_batch() loop
    -- statement against deltaplan_batch
    call deltaplan.finish_batch();
end loop;
call deltaplan.finalize();
```

`examples/oracle/example_customer_metrics.sql` and `examples/postgres/example_customer_metrics.sql` show a full session. Lookback is not stored. The column that moves forward is `watermark`.

## Tests

The Oracle suite is `pkg_deltaplan_test.run`. The PostgreSQL suite is `deltaplan_test.run()`. Both cover a static load, the lookback window, batches, a resume after rollback, and the errors that keep a watermark in place. `pkg_deltaplan_test_edges.run` and `deltaplan_test.run_edges()` cover the initial bound, a watermark that must not move backwards, segments, the strict timestamp predicate, fractional lookback, duplicate keys, null key parts, and the capture errors.

`make test-consistency` compares an incremental customer-metrics mart with a full refresh of the same SQL, using xoverrr. `docs/consistency.md` records what matches. Hard deletes do not: capture never sees a removed source row.

```bash
make test-oracle     # SQL*Plus; override ORACLE_CONNECT
make test-postgres   # psql inside a container; override PG_CONTAINER, PGUSER, PGPASSWORD, PGDATABASE
```

`tests/postgres/run.sh` copies the scripts into the container, so the host does not need `psql`.

A new pair of databases, on ports that do not collide with an existing 1521 and 5433:

```bash
docker compose -f tests/docker/docker-compose.yml up --wait
ORACLE_CONNECT=test/test_pass@//localhost:1522/FREEPDB1 make test-oracle
PG_CONTAINER=deltaplan-postgres make test-postgres
```

The Oracle image is [gvenzl/oracle-free](https://github.com/gvenzl/oci-oracle-free). It does not need an Oracle registry login. The first start is slow.

These checks were run against Oracle Free on `localhost:1521/test_db` (user `test`) and PostgreSQL 15.4 on `localhost:5433` (user `test_user`, database `test_db`). Both printed a passing line: `pkg_deltaplan_test: passed` and `deltaplan_test: passed`.
