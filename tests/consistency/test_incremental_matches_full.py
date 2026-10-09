"""Incremental customer metrics must match a full refresh of the same SQL.

xoverrr compares the incremental table with the full-refresh table: row counts,
row values, and aggregates. Cases the watermark design cannot see are asserted
to diverge, and the report names the customer that drifted.
"""

from datetime import datetime, timedelta

from harness import (
    CAPTURE_ORDERS,
    CAPTURE_ORDERS_COMPLETED,
    T0,
    hours,
)


def test_first_load_matches_full_refresh(mart):
    mart.seed()
    mart.run_incremental()
    mart.rebuild_full()
    mart.assert_equal("first load")


def test_history_before_2000_matches_full_refresh(mart):
    mart.seed(ts=datetime(1998, 5, 1, 8, 0, 0))
    mart.run_incremental(lookback=100000)
    mart.rebuild_full()
    mart.assert_equal("1998")
    assert mart.watermark("orders").year == 1998


def test_empty_sources_match(mart):
    mart.run_incremental()
    mart.rebuild_full()
    mart.assert_equal("empty")


def test_inserts_updates_and_empty_rerun(mart):
    mart.seed()
    mart.run_incremental()
    mart.rebuild_full()
    mart.assert_equal("baseline")
    stored = mart.watermark("orders")

    mart.add_customer(50, hours(5), region="east")
    mart.add_order(500, 50, hours(5), status="completed", discount=0.2)
    mart.add_item(500, 1, hours(5), qty=3, price=40)
    mart.set_customer(1, hours(5), region="west")
    order_id, product_id = mart.first_item(1)
    mart.set_item(order_id, product_id, hours(5), price=80, qty=4)
    mart.run_incremental()
    mart.rebuild_full()
    mart.assert_equal("insert and update")
    assert mart.watermark("orders") > stored

    mart.run_incremental()
    mart.rebuild_full()
    mart.assert_equal("empty delta")
    assert mart.watermark("orders") == mart.watermark("customers")


def test_consecutive_waves_including_an_empty_one(mart):
    mart.seed()
    mart.run_incremental()
    mart.rebuild_full()
    mart.assert_equal("wave 0")

    order_id, product_id = mart.first_item(2)
    mart.set_item(order_id, product_id, hours(1), price=15)
    mart.run_incremental()
    mart.rebuild_full()
    mart.assert_equal("wave 1")

    mart.run_incremental()
    mart.rebuild_full()
    mart.assert_equal("wave 2 empty")

    mart.add_order(610, 3, hours(3), status="cancelled", discount=0.5)
    mart.add_item(610, 2, hours(3), qty=2, price=12)
    mart.set_order(mart.order_id(3, 1), hours(3), status="completed", discount=0)
    mart.run_incremental()
    mart.rebuild_full()
    mart.assert_equal("wave 3")


def test_mixed_batch_matches_full_refresh(mart):
    _plant_mixed(mart)
    mart.run_incremental(batch_size=1)
    mart.rebuild_full()
    mart.assert_equal("batched")


def test_mixed_unbatched_matches_full_refresh(mart):
    _plant_mixed(mart)
    mart.run_incremental()
    mart.rebuild_full()
    mart.assert_equal("unbatched")


def test_null_measures_match(mart):
    mart.seed(n_customers=3, orders_per=1, items_per=2)
    mart.run_incremental()
    order_id, product_id = mart.first_item(1)
    mart.set_item(order_id, product_id, hours(2), price=None)
    other = mart.order_id(2, 1)
    cur = mart._cur()
    cur.execute(
        "update cm.order_items set price = null, updated_at = %s where order_id = %s",
        (hours(2), other),
    )
    mart.run_incremental()
    mart.rebuild_full()
    mart.assert_equal("null prices")


def test_item_only_change_matches_when_items_are_captured(mart):
    mart.seed()
    mart.run_incremental()
    order_id, product_id = mart.first_item(1)
    mart.set_item(order_id, product_id, hours(4), price=123.45, qty=9)
    mart.run_incremental()
    mart.rebuild_full()
    mart.assert_equal("item capture")


def test_item_only_change_diverges_without_item_capture(mart):
    mart.seed()
    mart.run_incremental()
    order_id, product_id = mart.first_item(1)
    mart.set_item(order_id, product_id, hours(4), price=123.45, qty=9)
    mart.run_incremental(sources=("customers", "orders"))
    mart.rebuild_full()
    mart.assert_diverges("missing item capture", mention=1)


def test_delete_item_matches_when_parent_is_touched(mart):
    mart.seed()
    mart.run_incremental()
    order_id, product_id = mart.first_item(1)
    mart.delete_item(order_id, product_id)
    mart.set_order(order_id, hours(6), status="completed")
    mart.run_incremental()
    mart.rebuild_full()
    mart.assert_equal("delete with touch")


def test_delete_last_items_removes_the_customer(mart):
    mart.seed(n_customers=3, orders_per=1, items_per=1)
    mart.run_incremental()
    order_id, product_id = mart.first_item(1)
    mart.delete_item(order_id, product_id)
    mart.set_customer(1, hours(6), region="south")
    mart.run_incremental()
    mart.rebuild_full()
    mart.assert_equal("customer removed")
    cur = mart._cur()
    cur.execute("select count(*) from cm.metrics_inc where customer_id = 1")
    assert cur.fetchone()[0] == 0


def test_hard_delete_is_not_captured(mart):
    """Source DELETE is invisible by design. See the README."""
    mart.seed()
    mart.run_incremental()
    order_id, product_id = mart.first_item(2)
    mart.delete_item(order_id, product_id)
    mart.run_incremental()
    mart.rebuild_full()
    mart.assert_diverges("hard delete", mention=2)


def test_hard_delete_of_customer_is_not_captured(mart):
    """Deleting the customer row leaves no watermark. The mart row stays."""
    mart.seed()
    mart.run_incremental()
    mart.delete_customer(1)
    mart.run_incremental()
    mart.rebuild_full()
    mart.assert_diverges("deleted customer", mention=1)


def test_reassign_matches_when_prior_customer_is_captured(mart):
    mart.seed()
    mart.run_incremental()
    order_id = mart.order_id(1, 1)
    mart.set_order(order_id, hours(8), customer_id=2, prior_customer_id=1)
    mart.run_incremental(use_prior=True)
    mart.rebuild_full()
    mart.assert_equal("reassign")


def test_reassign_diverges_when_prior_customer_is_omitted(mart):
    mart.seed()
    mart.run_incremental()
    order_id = mart.order_id(1, 1)
    mart.set_order(order_id, hours(8), customer_id=2, prior_customer_id=1)
    mart.run_incremental(use_prior=False)
    mart.rebuild_full()
    mart.assert_diverges("reassign without prior", mention=1)


def test_late_row_inside_lookback_matches(mart):
    mart.seed()
    mart.run_incremental()
    late = mart.watermark("orders") - timedelta(minutes=30)
    mart.add_order(700, 1, late, status="completed", discount=0.25)
    mart.add_item(700, 1, late, qty=6, price=18)
    mart.run_incremental(lookback=2)
    mart.rebuild_full()
    mart.assert_equal("inside lookback")


def test_late_row_outside_lookback_diverges(mart):
    mart.seed()
    mart.run_incremental()
    late = mart.watermark("orders") - timedelta(hours=5)
    # This customer has no row inside the lookback window, so the late order
    # is the only candidate and it loses to the strict bound.
    mart.add_customer(60, late)
    mart.add_order(701, 60, late, status="completed", discount=0.25)
    mart.add_item(701, 1, late, qty=6, price=18)
    mart.run_incremental(lookback=2)
    mart.rebuild_full()
    mart.assert_diverges("outside lookback", mention=60)


def test_equal_timestamp_matches_with_lookback(mart):
    mart.seed()
    mart.run_incremental()
    stamp = mart.watermark("orders")
    mart.add_order(702, 3, stamp, status="completed")
    mart.add_item(702, 2, stamp, qty=2, price=30)
    mart.run_incremental(lookback=1)
    mart.rebuild_full()
    mart.assert_equal("same timestamp")


def test_equal_timestamp_diverges_without_lookback(mart):
    mart.seed()
    mart.run_incremental()
    stamp = mart.watermark("orders")
    mart.add_order(703, 3, stamp, status="completed")
    mart.add_item(703, 2, stamp, qty=2, price=30)
    mart.run_incremental(lookback=0)
    mart.rebuild_full()
    mart.assert_diverges("same timestamp hidden", mention=3)


def test_backdated_update_diverges_until_lookback_covers_it(mart):
    mart.seed()
    mart.run_incremental()
    back = T0 - timedelta(days=3)
    cur = mart._cur()
    # Move every timestamp for this customer backwards. A one-day lookback
    # then has no row that can bring the key back.
    cur.execute("update cm.customers set updated_at = %s where id = 4", (back,))
    cur.execute("update cm.orders set updated_at = %s where customer_id = 4", (back,))
    cur.execute(
        """
        update cm.order_items oi
        set updated_at = %s, price = 1
        from cm.orders o
        where o.id = oi.order_id and o.customer_id = 4
        """,
        (back,),
    )
    mart.run_incremental(lookback=24)
    mart.rebuild_full()
    mart.assert_diverges("backdated", mention=4)

    mart.run_incremental(lookback=24 * 4)
    mart.rebuild_full()
    mart.assert_equal("backdated covered")


def test_sibling_row_inside_lookback_applies_a_backdated_change(mart):
    mart.seed()
    mart.run_incremental()
    order_id, product_id = mart.first_item(4)
    mart.set_item(order_id, product_id, T0 - timedelta(days=3), price=1)
    # The other rows for this customer still sit on the watermark, inside
    # a one-hour lookback, so the key is recomputed from current rows.
    mart.run_incremental(lookback=1)
    mart.rebuild_full()
    mart.assert_equal("sibling in window")


def test_null_updated_at_is_invisible(mart):
    mart.seed()
    mart.run_incremental()
    order_id, product_id = mart.first_item(1)
    cur = mart._cur()
    cur.execute(
        """
        update cm.order_items
        set price = 999, updated_at = null
        where order_id = %s and product_id = %s
        """,
        (order_id, product_id),
    )
    mart.run_incremental()
    mart.rebuild_full()
    mart.assert_diverges("null updated_at", mention=1)


def test_filtered_capture_lets_the_watermark_skip_a_row(mart):
    mart.seed(n_customers=2, orders_per=1, items_per=1)
    cur = mart._cur()
    cur.execute("update cm.orders set status = 'completed'")
    mart.run_incremental()
    mart.add_order(900, 1, hours(2), status="new")
    mart.add_item(900, 1, hours(2), qty=1, price=50)
    mart.add_order(901, 2, hours(3), status="completed")
    mart.add_item(901, 1, hours(3), qty=1, price=50)
    mart.run_incremental(sources=("orders",), order_sql=CAPTURE_ORDERS_COMPLETED)
    assert mart.watermark("orders") == hours(3)
    mart.set_order(900, hours(2), status="completed")
    mart.run_incremental(sources=("orders",), order_sql=CAPTURE_ORDERS_COMPLETED)
    mart.rebuild_full()
    mart.assert_diverges("watermark skipped a filtered row", mention=1)


def test_duplicate_capture_rows_do_not_change_measures(mart):
    mart.seed()
    mart.run_incremental()
    mart.set_customer(1, hours(9), region="south")
    mart.set_order(mart.order_id(1, 1), hours(9), discount=0.15)
    order_id, product_id = mart.first_item(1)
    mart.set_item(order_id, product_id, hours(9), price=70)
    mart.capture()
    # A second capture of the same stream appends another copy of the key.
    mart._cur().execute("call deltaplan.capture_delta('orders', %s)", (CAPTURE_ORDERS,))
    mart.apply()
    mart._cur().execute("call deltaplan.finalize()")
    mart.rebuild_full()
    mart.assert_equal("duplicate capture")


def test_joining_deltaplan_keys_multiplies_measures(mart):
    mart.seed()
    mart.run_incremental()
    mart.set_customer(1, hours(9), region="south")
    mart.set_order(mart.order_id(1, 1), hours(9), discount=0.15)
    order_id, product_id = mart.first_item(1)
    mart.set_item(order_id, product_id, hours(9), price=70)
    mart.capture()
    mart.apply_inflated()
    mart.rebuild_full()
    mart.assert_diverges("raw keys", mart="bad", mention=1)
    mart.apply()
    mart._cur().execute("call deltaplan.finalize()")
    mart.rebuild_full()
    mart.assert_equal("keyset")


def test_product_grain_matches_full_refresh(mart):
    mart.seed()
    mart.run_incremental(marts=("product",))
    mart.rebuild_full(marts=("product",))
    mart.assert_equal("product baseline", mart="product")

    order_id, product_id = mart.first_item(2)
    mart.delete_item(order_id, product_id)
    mart.set_order(order_id, hours(4), discount=0.05)
    mart._cur().execute(
        "insert into cm.products (id, category, updated_at) values (99, 'cat-99', %s)",
        (hours(4),),
    )
    mart.add_item(order_id, 99, hours(4), qty=8, price=11)
    mart.run_incremental(marts=("product",))
    mart.rebuild_full(marts=("product",))
    mart.assert_equal("product delta", mart="product")


def test_customer_without_orders_stays_out_of_the_mart(mart):
    mart.seed(n_customers=3)
    mart.run_incremental()
    mart.rebuild_full()
    mart.assert_equal("no empty customers")
    cur = mart._cur()
    cur.execute("select count(*) from cm.metrics_full where customer_id = 4")
    assert cur.fetchone()[0] == 0
    cur.execute("select count(*) from cm.customers")
    assert cur.fetchone()[0] == 4


def _plant_mixed(mart):
    mart.seed(n_customers=5, orders_per=2, items_per=2)
    mart.run_incremental()
    mart.add_customer(80, hours(7))
    mart.add_order(800, 80, hours(7), status="completed", discount=0.05)
    mart.add_item(800, 1, hours(7), qty=2, price=16)
    mart.add_item(800, 3, hours(7), qty=1, price=None)
    order_id, product_id = mart.first_item(2)
    mart.set_item(order_id, product_id, hours(7), price=44, qty=5)
    mart.delete_item(*mart.first_item(3))
    mart.set_customer(3, hours(7), name="touched")
    mart.set_order(mart.order_id(4, 1), hours(7), customer_id=5, prior_customer_id=4)
    mart.set_order(mart.order_id(5, 2), hours(7), status="completed", discount=0.4)
