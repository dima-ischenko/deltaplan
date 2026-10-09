# Incremental result vs full refresh

Deltaplan captures business keys whose source watermark moved, and the calculation you write recomputes those keys. Compared with a full refresh of the same SQL, that matches when every affected key is still in the source and is returned by the capture. It does not match when the key was removed or was never emitted.

The comparison is `tests/consistency`. xoverrr checks row counts, row values, and aggregates of the incremental mart against a full refresh. The engine checks are `deltaplan_test.run_edges()` and `pkg_deltaplan_test_edges.run`.

## Fixes

**The first load used 1 January 2000 as the bound.** With no stored watermark, `capture_delta` treated the predicate as `updated_at > timestamp '2000-01-01'`. A row stamped earlier never entered the mart, while a full refresh included it. The bound is now the minimum timestamp (`-infinity` on PostgreSQL, 1 January 4712 BCE on Oracle) until a watermark exists. Lookback is subtracted only from a stored watermark.

```sql
-- before: key count 0, mart misses the row
-- after:  key count 1, watermark 1999-12-31
insert into inc_test_a (id, amount, updated_at)
values ('old', 4, timestamp '1999-12-31 23:00:00');
call deltaplan.initialize('inc_test_tgt', 'all', 0);
call deltaplan.capture_delta('inc_test_a',
    'select id, null::text, null::text, updated_at from inc_test_a where updated_at > :since');
```

**The PostgreSQL example did not capture `order_items`.** An item price change left `customer_metrics` stale. The example now captures `order_items` the same way the Oracle example does.

**A captured customer with no remaining line items stayed in the mart.** The example merge only inserted and updated. Both examples now delete a captured key that no longer produces a row. That delete runs only for keys already captured. It is not delete capture.

**`deltaplan_keys` has one row per source.** Joining it into `sum` or `count` multiplies a customer once per source. `deltaplan_keyset` is the distinct `(pk_1, pk_2, pk_3)`. `deltaplan_batch` is already distinct. Aggregates read one of those.

## Hard deletes

Hard deletes are not supported. Capture reads a row that is still there. A `DELETE` leaves no watermark, and lookback does not bring the row back. The tests `test_hard_delete_is_not_captured` and `test_hard_delete_of_customer_is_not_captured` lock that: after the delete, xoverrr reports the incremental mart and the full refresh as different.

A mart key can still be recomputed when some surviving row moves and the capture statement returns the key. Deleting an item and touching the order, or deleting the last items and touching the customer, matches a full refresh. Removing the customer row itself does not.

## Other cases that do not match

These are consequences of the watermark predicate `value > :since`. The tests expect the mismatch.

| Case | What happens |
| --- | --- |
| Order moves to another customer and the capture returns only the new `customer_id` | The previous customer's mart row keeps the order. Returning `prior_customer_id` as well matches. |
| New row stamped at or below `watermark - lookback`, and that customer has no other row inside the window | The key is not captured. |
| Row stamped exactly at the watermark, lookback 0 | Excluded by `>`. A lookback that reaches it is included. |
| `updated_at` is null | `null > :since` is not true, so the change is invisible. |
| Capture keeps only `status = 'completed'`, and a later completed row has a higher timestamp | The watermark moves past an older row that was filtered out. Completing that row without a new timestamp does not capture it. |

A backdated change is applied when some other row for the same key sits inside the lookback window. The key is captured from that sibling and recomputed from current rows, so the incremental mart matches.

## What matches

Inserts, updates, null measures, an empty rerun, several waves in a row, a batch size of one against the same load without batches, a customer-product grain, duplicate capture rows read through `deltaplan_keyset`, a late row inside the lookback, and history before 2000. xoverrr compares counts, samples, and aggregates for each of these. The PostgreSQL run of that suite is 28 tests, all passing. `deltaplan_test.run` and `deltaplan_test.run_edges` pass on PostgreSQL 16.15. The Oracle edge package mirrors the engine checks and was not executed here.
