# Deltaplan (DPL)

Incremental load of a target table on Oracle and PostgreSQL. dpl stores a watermark per source, captures the keys that moved, and leaves the refresh SQL to you. A watermark never moves backwards.

- Oracle: [deploy](lib/oracle/deploy.md), [call](lib/oracle/README.md)
- PostgreSQL and Greenplum: [deploy](lib/postgres/deploy.md), [call](lib/postgres/README.md)

Try it from [`demo/`](demo/README.md).

## API

On Oracle the entry point is `pkg_dpl`. On PostgreSQL the same names are functions in the install schema (`perform` from PL/pgSQL).

A run is `initialize` → `capture_delta` per source → refresh SQL → `finalize`. Batches are optional: `prepare_batches`, then `next_batch` / refresh / `finish_batch`.

### initialize(p_target_table, p_data_segment, p_lookback_hours)

Starts a run and clears keys of this target and segment.

| Parameter | Required | Default | Effect |
| --- | --- | --- | --- |
| `p_target_table` | yes | — | Target being loaded. |
| `p_data_segment` | no | `'all'` | Independent watermark slice of this target. |
| `p_lookback_hours` | no | `0` | Hours subtracted from the stored watermark when binding `:since`. Fractions allowed. `0` binds the stored watermark. Not written to `dpl_watermark`. |

### capture_delta(p_source_table, p_sql, p_lookback_hours)

Inserts changed keys into `dpl_keys_tmp`.

| Parameter | Required | Default | Effect |
| --- | --- | --- | --- |
| `p_source_table` | yes | — | Source name stored with the watermark. |
| `p_sql` | yes | — | Must return `pk_1` and `watermark`. `pk_2` and `pk_3` are optional. Must contain `:since` exactly once. Keep the predicate `value > :since`. |
| `p_lookback_hours` | no | `null` | Lookback for this source. `null` uses the value from `initialize`. |

`:since` is the stored watermark minus the lookback. With no stored row the bound is `2000-01-01`.

### prepare_batches(p_batch_size [, p_commit_batch])

Numbers distinct keys. Skip it to refresh every key from `dpl_keys_tmp` in one statement.

| Parameter | Required | Default | Effect |
| --- | --- | --- | --- |
| `p_batch_size` | no | `5000` | Distinct keys per batch. |
| `p_commit_batch` | no | `true` | Oracle only. When true, `finish_batch` commits that batch. PostgreSQL never commits; commit after `finish_batch` yourself. |

### next_batch() → boolean

Loads the next unfinished batch into `dpl_batch_tmp`. Returns true while a batch is open, false when none remain. Do not commit between `next_batch` and `finish_batch`: that empties `dpl_batch_tmp`.

### finish_batch([p_merged])

Marks the open batch done.

| Parameter | Required | Default | Effect |
| --- | --- | --- | --- |
| `p_merged` | no | `null` | PostgreSQL only. Row count for the log. Oracle reads `sql%rowcount` of the preceding DML; call it immediately after the refresh. |

### finalize()

Writes, for each source, the greatest captured watermark. Never moves a watermark backwards. Does not commit. Errors if a batch is still unfinished; that error does not roll back. Commit after it to store the watermark.

After a failure, repeat from `initialize`. The refresh SQL must be idempotent.

### Session getters

No parameters. Return `null` when no run is open.

| Method | Returns |
| --- | --- |
| `get_target_table()` | Target of the current run. |
| `get_data_segment()` | Segment of the current run. Use it in capture and refresh SQL. |
| `get_lookback_hours()` | Lookback passed to `initialize`. |
| `get_batch_no()` | Open batch number, or `null`. |

Without batches the refresh reads `dpl_keys_tmp` where `target_table = get_target_table` and `data_segment = get_data_segment`. With batches it reads `dpl_batch_tmp`. A key from several sources is assigned to one batch.

## Tables

Same names and column order on Oracle and PostgreSQL.

`dpl_watermark` is permanent. One row per `(target_table, data_segment, source_table)`.

| Column | Meaning |
| --- | --- |
| `target_table`, `data_segment`, `source_table` | Grain of the row |
| `watermark` | Greatest source value fully applied |
| `updated_at` | Time of the last `finalize` write |

`dpl_keys_tmp` holds every key of the current run. Rows survive a commit and last until the session ends.

| Column | Meaning |
| --- | --- |
| `target_table`, `data_segment`, `source_table` | Same grain as `dpl_watermark` |
| `pk_1`, `pk_2`, `pk_3` | Business key of the target row |
| `watermark` | Source value of this key |
| `batch_no`, `batch_done` | Set by `prepare_batches`. `batch_done` becomes `1` after `finish_batch` |

`dpl_batch_tmp` holds `pk_1`, `pk_2`, `pk_3` of the open batch. A commit empties it.

## Data segments

Use a named `p_data_segment` when the same target is loaded in independent slices. Each slice has its own watermark. Pass the same predicate in capture and refresh SQL:

```sql
pkg_dpl.initialize('customer_metrics', 'fr', 2);

pkg_dpl.capture_delta('orders', q'[
    select customer_id as pk_1,
           max(updated_at) as watermark
    from orders
    where country_code = pkg_dpl.get_data_segment
      and updated_at > :since
    group by customer_id
]');
```

On PostgreSQL the same calls are `initialize` and `get_data_segment()`.

## Hard deletes

Not supported. A physical `DELETE` never reaches `dpl_keys_tmp`. To drop a target row, keep a source row whose watermark still moves (flag, tombstone, audit) and delete it in the refresh SQL.

## Tests

```bash
docker compose -f tests/docker/docker-compose.yml up --wait
ORACLE_CONTAINER=dpl-oracle \
ORACLE_CONNECT=test/test_pass@//localhost:1521/FREEPDB1 \
PG_CONTAINER=dpl-postgres \
make test
```

`make` without those variables uses containers named `oracle` and `postgres`. The Oracle image is [gvenzl/oracle-free](https://github.com/gvenzl/oci-oracle-free); the first start takes several minutes.
