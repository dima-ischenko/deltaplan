# deltaplan

Deltaplan is a small library for incremental loads of a target table on Oracle and PostgreSQL. It keeps a watermark for each source, captures the primary keys that have moved since that watermark, and leaves the refresh statement to you. You recalculate only those keys. Deltaplan never moves a watermark backwards.

The refresh statement is ordinary SQL. Batches are optional: a small target table can be refreshed in one statement; a large one can be split into committed slices.

- Oracle: [deploy](oracle/deploy.md), [run](oracle/README.md)
- PostgreSQL and Greenplum: [deploy](postgres/deploy.md), [run](postgres/README.md)

## How a run works

1. Call `initialize` with the target table, a data segment (default `all`), and a lookback in hours (default `0`).
2. Call `capture_delta` once for each source. Each call inserts keys into `deltaplan_keys_tmp`.
3. Refresh the target table for those keys. Without batches, one statement reads `deltaplan_keys_tmp`. With batches, each statement reads `deltaplan_batch_tmp`.
4. Call `finalize`. It writes, for each source, the greatest watermark captured in this run.

A key that arrives from several sources is assigned to a single batch.

## Capture SQL

The capture statement must return four columns: `pk_1`, `pk_2`, `pk_3`, and `watermark`. Leave `pk_2` and `pk_3` null when the key is shorter.

The statement must contain the placeholder `:since` exactly once. `:since` is the stored watermark minus the lookback; it is not the stored watermark itself. The predicate remains strict: `value > :since`. The lookback is applied when the bound is read and is not stored.

## Tables

The tables have the same names and the same column order on Oracle and PostgreSQL.

`deltaplan_watermark` is permanent. There is one row for each combination of target, segment, and source. `finalize` advances `watermark` and sets `updated_at`.

| Column | Meaning |
| --- | --- |
| `target_table`, `data_segment`, `source_table` | Grain of the row |
| `watermark` | Greatest source value that has been fully applied |
| `updated_at` | Time at which `finalize` last wrote the row |

`deltaplan_keys_tmp` holds every key captured in the current run. The rows survive a commit and last until the session ends. A run without batches reads this table, restricted to the current target and segment.

| Column | Meaning |
| --- | --- |
| `target_table`, `data_segment`, `source_table` | Same grain as `deltaplan_watermark` |
| `pk_1`, `pk_2`, `pk_3` | Business key of the target row |
| `watermark` | Source value of this key |
| `batch_no`, `batch_done` | Filled by `prepare_batches`. `batch_done` becomes `1` after `finish_batch` |

`deltaplan_batch_tmp` holds the business key of the open batch: `pk_1`, `pk_2`, `pk_3`, in the same order as in `deltaplan_keys_tmp`. A commit empties the table. The refresh statement of a batched run reads this table.

Session tables take the suffix `_tmp`, the usual warehouse marker for a temporary relation. `_gtt` is not used: it would describe Oracle only, while PostgreSQL and Greenplum use session `TEMP` tables.

## Batches

`prepare_batches` numbers the distinct keys. The default size is `5000`.

The loop is then `next_batch`, the refresh statement against `deltaplan_batch_tmp`, and `finish_batch`. Call `finish_batch` immediately after that statement. `next_batch` returns false when no unfinished batch remains. Call `finalize` after the loop. It raises an error while a batch is unfinished, and that error does not roll the session back.

Commit behaviour differs by engine: [Oracle](oracle/README.md), [PostgreSQL](postgres/README.md).

## Data segments

A watermark is stored for the triple `(target_table, data_segment, source_table)`. The default segment is `all`, which is enough when the target table is loaded as one unit.

Use a named segment when the same target must be loaded in independent slices. Typical cases are a country, a legal entity, or a book of business. Each slice then has its own watermark, so a late load for France does not hold back Germany, and a rerun of one slice does not recapture keys of another.

Deltaplan does not read `data_segment` out of the source tables. You pass the slice into `initialize`, and you apply the same predicate in the capture SQL and in the refresh statement. `get_data_segment` returns the value of the current run, so the statements stay aligned.

```sql
pkg_deltaplan.initialize('customer_metrics', 'fr', 2);

pkg_deltaplan.capture_delta('orders', q'[
    select customer_id as pk_1,
           null        as pk_2,
           null        as pk_3,
           max(updated_at) as watermark
    from orders
    where country_code = pkg_deltaplan.get_data_segment
      and updated_at > :since
    group by customer_id
]');
```

Without batches, the refresh statement still reads `deltaplan_keys_tmp` restricted to that segment:

```sql
where k.target_table = pkg_deltaplan.get_target_table
  and k.data_segment = pkg_deltaplan.get_data_segment
```

`deltaplan_batch_tmp` does not store the segment: it contains only the keys of the open batch, which already belong to the current run. A second session may call `initialize` for another segment of the same target; the watermarks remain separate.

On PostgreSQL the same calls are `deltaplan.initialize` and `deltaplan.get_data_segment()`.

## Hard deletes

Hard deletes are not supported.

Capture can return a key only while that key still exists in the source and its watermark is greater than `:since`. A physical `DELETE` removes the source row, so the key never reaches `deltaplan_keys_tmp` and the target row is left unchanged.

If a removal must reach the target table, keep a row in the source: a deleted flag, a tombstone, or an audit record, with a watermark that continues to move. The refresh statement then deletes or updates the corresponding key.

## Tests

Both suites copy the scripts into a database container. The host does not need `sqlplus` or `psql`. They cover a static load, the lookback window, batches, a resume after rollback, and the errors that keep a watermark in place. The passing lines are `pkg_deltaplan_test: passed` and `deltaplan_test: passed`.

```bash
docker compose -f tests/docker/docker-compose.yml up --wait
ORACLE_CONTAINER=deltaplan-oracle \
ORACLE_CONNECT=test/test_pass@//localhost:1521/FREEPDB1 \
PG_CONTAINER=deltaplan-postgres \
make test
```

`make` without those variables uses containers named `oracle` and `postgres`. `ORACLE_CONNECT` is passed into the Oracle container, so the host port does not appear in the string.

The Oracle image is [gvenzl/oracle-free](https://github.com/gvenzl/oci-oracle-free). It does not require an Oracle registry login. The first start takes several minutes.

GitHub Actions runs the same suites. Open **Actions**, choose **Tests**, and run the workflow. A push and a pull request start it as well.
