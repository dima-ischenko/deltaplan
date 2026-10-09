"""Customer-metrics mart driven by deltaplan, compared with xoverrr.

The incremental path captures changed customer ids and recomputes those
customers from the current source rows. A customer who no longer has a line
item is deleted. That is the calculation a full refresh expresses with the
same joins and aggregates.
"""

from datetime import datetime, timedelta

from xoverrr import CHECK_SUCCESS, DataQualityChecker, DataReference

T0 = datetime(2024, 1, 15, 10, 0, 0)

CAPTURE_CUSTOMERS = """
    select id::text as pk_1,
           null::text as pk_2,
           null::text as pk_3,
           updated_at as watermark
    from cm.customers
    where updated_at > :since
"""

CAPTURE_ORDERS = """
    select k.pk_1,
           null::text as pk_2,
           null::text as pk_3,
           max(k.watermark) as watermark
    from (
        select customer_id::text as pk_1, updated_at as watermark
        from cm.orders
        where customer_id is not null
        union all
        select prior_customer_id::text, updated_at
        from cm.orders
        where prior_customer_id is not null
    ) k
    where k.watermark > :since
    group by k.pk_1
"""

CAPTURE_ORDERS_CURRENT_ONLY = """
    select customer_id::text as pk_1,
           null::text as pk_2,
           null::text as pk_3,
           max(updated_at) as watermark
    from cm.orders
    where updated_at > :since
      and customer_id is not null
    group by customer_id
"""

CAPTURE_ORDERS_COMPLETED = """
    select customer_id::text as pk_1,
           null::text as pk_2,
           null::text as pk_3,
           max(updated_at) as watermark
    from cm.orders
    where updated_at > :since
      and status = 'completed'
      and customer_id is not null
    group by customer_id
"""

CAPTURE_ITEMS = """
    select o.customer_id::text as pk_1,
           null::text as pk_2,
           null::text as pk_3,
           max(oi.updated_at) as watermark
    from cm.order_items oi
    join cm.orders o on o.id = oi.order_id
    where oi.updated_at > :since
      and o.customer_id is not null
    group by o.customer_id
"""

SCHEMA_SQL = """
drop schema if exists cm cascade;
create schema cm;

create table cm.products (
    id         bigint primary key,
    category   text not null,
    updated_at timestamp
);

create table cm.customers (
    id         bigint primary key,
    name       text not null,
    region     text not null,
    updated_at timestamp
);

create table cm.orders (
    id                 bigint primary key,
    customer_id        bigint,
    order_date         date not null,
    status             text not null,
    order_discount     numeric not null,
    prior_customer_id  bigint,
    updated_at         timestamp
);

create table cm.order_items (
    order_id   bigint not null,
    product_id bigint not null,
    quantity   numeric,
    price      numeric,
    updated_at timestamp,
    primary key (order_id, product_id)
);

create table cm.metrics_inc (
    customer_id    bigint primary key,
    min_amount     numeric(20, 6),
    max_amount     numeric(20, 6),
    avg_amount     numeric(20, 6),
    last_order_id  bigint,
    cnt_completed  bigint,
    revenue        numeric(20, 6)
);

create table cm.metrics_full (like cm.metrics_inc including all);
create table cm.metrics_bad (like cm.metrics_inc including all);

create table cm.product_inc (
    customer_id bigint not null,
    product_id  bigint not null,
    category    text not null,
    qty         numeric(20, 6),
    revenue     numeric(20, 6),
    primary key (customer_id, product_id)
);

create table cm.product_full (like cm.product_inc including all);

create index ix_customers_updated on cm.customers (updated_at);
create index ix_orders_updated on cm.orders (updated_at);
create index ix_orders_customer on cm.orders (customer_id);
create index ix_order_items_updated on cm.order_items (updated_at);
create index ix_order_items_order on cm.order_items (order_id);
"""

METRICS_COLUMNS = """
    customer_id, min_amount, max_amount, avg_amount,
    last_order_id, cnt_completed, revenue
"""

METRICS_SELECT = """
    select c.id,
           round(min(x.line), 6),
           round(max(x.line), 6),
           round(avg(x.line), 6),
           (array_agg(o.id order by o.order_date desc, o.id desc))[1],
           count(*) filter (where o.status = 'completed'),
           round(sum(x.line), 6)
    from cm.customers c
    join cm.orders o on o.customer_id = c.id
    join cm.order_items oi on oi.order_id = o.id
    cross join lateral (
        select oi.quantity * oi.price * (1 - o.order_discount) as line
    ) x
    {extra_join}
    group by c.id
"""

PRODUCT_SELECT = """
    select o.customer_id,
           oi.product_id,
           min(p.category),
           round(sum(oi.quantity), 6),
           round(sum(oi.quantity * oi.price * (1 - o.order_discount)), 6)
    from cm.orders o
    join cm.order_items oi on oi.order_id = o.id
    join cm.products p on p.id = oi.product_id
    {extra_join}
    group by o.customer_id, oi.product_id
"""


class Mart:
    def __init__(self, conn, engine):
        self.conn = conn
        self.engine = engine
        self.n_customers = 0
        self.orders_per = 0
        self.items_per = 0
        self.n_products = 4

    def _cur(self):
        return self.conn.cursor()

    def reset(self):
        cur = self._cur()
        cur.execute(SCHEMA_SQL)
        cur.execute(
            "delete from public.deltaplan_watermark where target_table = 'customer_metrics'"
        )
        self.conn.commit()

    def seed(self, n_customers=4, orders_per=2, items_per=2, ts=T0, n_products=4):
        self.n_customers = n_customers
        self.orders_per = orders_per
        self.items_per = items_per
        self.n_products = n_products
        cur = self._cur()
        cur.execute(
            """
            insert into cm.products (id, category, updated_at)
            select n, 'cat-' || n, %s
            from generate_series(1, %s) n
            """,
            (ts, n_products),
        )
        cur.execute(
            """
            insert into cm.customers (id, name, region, updated_at)
            select n,
                   'customer-' || n,
                   (array['north','south','east','west'])[1 + mod(n, 4)],
                   %s
            from generate_series(1, %s) n
            """,
            (ts, n_customers + 1),
        )
        cur.execute(
            """
            insert into cm.orders (
                id, customer_id, order_date, status, order_discount, updated_at
            )
            select (c - 1) * %s + j,
                   c,
                   date '2023-01-01' + ((c - 1) * %s + j),
                   case when mod(j, 2) = 1 then 'completed' else 'cancelled' end,
                   case when mod(j, 2) = 0 then 0.10 else 0 end,
                   %s
            from generate_series(1, %s) c
            cross join generate_series(1, %s) j
            """,
            (orders_per, orders_per, ts, n_customers, orders_per),
        )
        cur.execute(
            """
            insert into cm.order_items (order_id, product_id, quantity, price, updated_at)
            select o.id,
                   1 + mod(o.id + k, %s),
                   k,
                   10 + (1 + mod(o.id + k, %s)),
                   %s
            from cm.orders o
            cross join generate_series(1, %s) k
            """,
            (n_products, n_products, ts, items_per),
        )
        self.conn.commit()

    def order_id(self, customer_id, nth=1):
        return (customer_id - 1) * self.orders_per + nth

    def first_item(self, customer_id):
        cur = self._cur()
        cur.execute(
            """
            select o.id, oi.product_id
            from cm.orders o
            join cm.order_items oi on oi.order_id = o.id
            where o.customer_id = %s
            order by o.id, oi.product_id
            limit 1
            """,
            (customer_id,),
        )
        return cur.fetchone()

    def watermark(self, source):
        cur = self._cur()
        cur.execute(
            """
            select watermark
            from public.deltaplan_watermark
            where target_table = 'customer_metrics'
              and data_segment = 'all'
              and source_table = %s
            """,
            (source,),
        )
        row = cur.fetchone()
        return None if row is None else row[0]

    def set_customer(self, customer_id, ts, **cols):
        self._update("cm.customers", {"id": customer_id}, ts, cols)

    def set_order(self, order_id, ts, **cols):
        self._update("cm.orders", {"id": order_id}, ts, cols)

    def set_item(self, order_id, product_id, ts, **cols):
        self._update(
            "cm.order_items",
            {"order_id": order_id, "product_id": product_id},
            ts,
            cols,
        )

    def _update(self, table, keys, ts, cols):
        aliases = {"qty": "quantity", "discount": "order_discount"}
        assigns = ["updated_at = %s"]
        params = [ts]
        for name, value in cols.items():
            column = aliases.get(name, name)
            assigns.append(f"{column} = %s")
            params.append(value)
        where = " and ".join(f"{name} = %s" for name in keys)
        params.extend(keys.values())
        cur = self._cur()
        cur.execute(
            f"update {table} set {', '.join(assigns)} where {where}",
            params,
        )
        if cur.rowcount != 1:
            raise AssertionError(f"update {table} changed {cur.rowcount} rows for {keys}")

    def add_customer(self, customer_id, ts, region="north"):
        self._cur().execute(
            """
            insert into cm.customers (id, name, region, updated_at)
            values (%s, %s, %s, %s)
            """,
            (customer_id, f"customer-{customer_id}", region, ts),
        )

    def add_order(
        self,
        order_id,
        customer_id,
        ts,
        status="completed",
        discount=0,
        order_date=None,
        prior_customer_id=None,
    ):
        self._cur().execute(
            """
            insert into cm.orders (
                id, customer_id, order_date, status, order_discount,
                prior_customer_id, updated_at
            ) values (%s, %s, %s, %s, %s, %s, %s)
            """,
            (
                order_id,
                customer_id,
                order_date or datetime(2024, 3, 1).date(),
                status,
                discount,
                prior_customer_id,
                ts,
            ),
        )

    def add_item(self, order_id, product_id, ts, qty=1, price=25):
        self._cur().execute(
            """
            insert into cm.order_items (order_id, product_id, quantity, price, updated_at)
            values (%s, %s, %s, %s, %s)
            """,
            (order_id, product_id, qty, price, ts),
        )

    def delete_item(self, order_id, product_id):
        cur = self._cur()
        cur.execute(
            "delete from cm.order_items where order_id = %s and product_id = %s",
            (order_id, product_id),
        )
        if cur.rowcount != 1:
            raise AssertionError("item delete removed %s rows" % cur.rowcount)

    def delete_order(self, order_id):
        cur = self._cur()
        cur.execute("delete from cm.order_items where order_id = %s", (order_id,))
        cur.execute("delete from cm.orders where id = %s", (order_id,))
        if cur.rowcount != 1:
            raise AssertionError("order delete removed %s rows" % cur.rowcount)

    def delete_customer(self, customer_id):
        cur = self._cur()
        cur.execute("delete from cm.customers where id = %s", (customer_id,))
        if cur.rowcount != 1:
            raise AssertionError("customer delete removed %s rows" % cur.rowcount)

    def capture(
        self,
        lookback=0,
        sources=("customers", "orders", "items"),
        use_prior=True,
        order_sql=None,
    ):
        cur = self._cur()
        cur.execute(
            "call deltaplan.initialize('customer_metrics', 'all', %s)",
            (lookback,),
        )
        if "customers" in sources:
            cur.execute(
                "call deltaplan.capture_delta('customers', %s)",
                (CAPTURE_CUSTOMERS,),
            )
        if "orders" in sources:
            sql = order_sql or (CAPTURE_ORDERS if use_prior else CAPTURE_ORDERS_CURRENT_ONLY)
            cur.execute("call deltaplan.capture_delta('orders', %s)", (sql,))
        if "items" in sources:
            cur.execute(
                "call deltaplan.capture_delta('order_items', %s)",
                (CAPTURE_ITEMS,),
            )

    def run_incremental(self, batch_size=None, marts=("metrics",), **capture_kwargs):
        self.capture(**capture_kwargs)
        self.apply(batch_size=batch_size, marts=marts)
        self._cur().execute("call deltaplan.finalize()")

    def apply(self, batch_size=None, marts=("metrics",), relation="deltaplan_keyset"):
        if batch_size is None:
            self._apply_relation(relation, marts)
            return
        cur = self._cur()
        cur.execute("call deltaplan.prepare_batches(%s, false)", (batch_size,))
        while True:
            cur.execute("select deltaplan.next_batch()")
            if not cur.fetchone()[0]:
                break
            self._apply_relation("deltaplan_batch", marts)
            cur.execute("call deltaplan.finish_batch()")

    def _apply_relation(self, relation, marts):
        cur = self._cur()
        cur.execute("drop table if exists cm_changed")
        cur.execute("create temp table cm_changed (customer_id bigint primary key)")
        if relation == "deltaplan_batch":
            cur.execute(
                """
                insert into cm_changed (customer_id)
                select distinct pk_1::bigint from deltaplan_batch
                """
            )
        else:
            cur.execute(
                f"""
                insert into cm_changed (customer_id)
                select distinct pk_1::bigint
                from {relation}
                where target_table = deltaplan.get_target_table()
                  and data_segment = deltaplan.get_data_segment()
                """
            )
        if "metrics" in marts:
            cur.execute("delete from cm.metrics_inc m using cm_changed c where m.customer_id = c.customer_id")
            cur.execute(
                f"""
                insert into cm.metrics_inc ({METRICS_COLUMNS})
                {METRICS_SELECT.format(extra_join="join cm_changed ch on ch.customer_id = c.id")}
                """
            )
        if "product" in marts:
            cur.execute(
                "delete from cm.product_inc p using cm_changed c where p.customer_id = c.customer_id"
            )
            cur.execute(
                f"""
                insert into cm.product_inc (customer_id, product_id, category, qty, revenue)
                {PRODUCT_SELECT.format(extra_join="join cm_changed ch on ch.customer_id = o.customer_id")}
                """
            )

    def apply_inflated(self):
        """Join deltaplan_keys, one row per source, straight into the aggregate."""
        cur = self._cur()
        cur.execute("delete from cm.metrics_bad")
        cur.execute("insert into cm.metrics_bad select * from cm.metrics_inc")
        cur.execute(
            """
            delete from cm.metrics_bad m
            using deltaplan_keyset k
            where k.target_table = deltaplan.get_target_table()
              and k.data_segment = deltaplan.get_data_segment()
              and k.pk_1 = m.customer_id::text
            """
        )
        cur.execute(
            f"""
            insert into cm.metrics_bad ({METRICS_COLUMNS})
            select c.id,
                   round(min(x.line), 6),
                   round(max(x.line), 6),
                   round(avg(x.line), 6),
                   (array_agg(o.id order by o.order_date desc, o.id desc))[1],
                   count(*) filter (where o.status = 'completed'),
                   round(sum(x.line), 6)
            from cm.customers c
            join deltaplan_keys k
              on k.pk_1 = c.id::text
             and k.target_table = deltaplan.get_target_table()
             and k.data_segment = deltaplan.get_data_segment()
            join cm.orders o on o.customer_id = c.id
            join cm.order_items oi on oi.order_id = o.id
            cross join lateral (
                select oi.quantity * oi.price * (1 - o.order_discount) as line
            ) x
            group by c.id
            """
        )

    def rebuild_full(self, marts=("metrics",)):
        cur = self._cur()
        if "metrics" in marts:
            cur.execute("truncate cm.metrics_full")
            cur.execute(
                f"""
                insert into cm.metrics_full ({METRICS_COLUMNS})
                {METRICS_SELECT.format(extra_join="")}
                """
            )
        if "product" in marts:
            cur.execute("truncate cm.product_full")
            cur.execute(
                f"""
                insert into cm.product_full (customer_id, product_id, category, qty, revenue)
                {PRODUCT_SELECT.format(extra_join="")}
                """
            )

    def commit(self):
        self.conn.commit()

    def assert_equal(self, label, mart="metrics"):
        self.commit()
        failures = self._compare(mart)
        if failures:
            text = "\n\n".join(failures)
            raise AssertionError(f"{label}: incremental mart differs from full refresh\n{text}")

    def assert_diverges(self, label, mart="metrics", mention=None):
        self.commit()
        failures = self._compare(mart)
        if not failures:
            raise AssertionError(f"{label}: expected incremental and full refresh to differ")
        if mention is not None and str(mention) not in "\n".join(failures):
            raise AssertionError(
                f"{label}: mismatch did not mention {mention}\n" + "\n".join(failures)
            )

    def _compare(self, mart):
        checker = DataQualityChecker(
            source_engine=self.engine,
            target_engine=self.engine,
            default_exclude_recent_hours=None,
            timezone="UTC",
        )
        if mart == "metrics":
            source = DataReference("metrics_inc", schema="cm")
            target = DataReference("metrics_full", schema="cm")
            pk = ["customer_id"]
            sums = ["revenue", "cnt_completed"]
            maxes = ["max_amount"]
        elif mart == "bad":
            source = DataReference("metrics_bad", schema="cm")
            target = DataReference("metrics_full", schema="cm")
            pk = ["customer_id"]
            sums = ["revenue", "cnt_completed"]
            maxes = ["max_amount"]
        elif mart == "product":
            source = DataReference("product_inc", schema="cm")
            target = DataReference("product_full", schema="cm")
            pk = ["customer_id", "product_id"]
            sums = ["revenue", "qty"]
            maxes = ["revenue"]
        else:
            raise ValueError(mart)

        reports = []
        count = checker.check_total_counts(
            source_table=source,
            target_table=target,
            check_name=f"{mart}-count",
        )
        samples = checker.check_samples(
            source_table=source,
            target_table=target,
            custom_primary_key=pk,
            check_name=f"{mart}-samples",
        )
        aggregates = checker.check_aggregates(
            source=source,
            target=target,
            sum_columns=sums,
            max_columns=maxes,
            include_count=True,
            check_name=f"{mart}-aggregates",
        )
        for result in (count, samples, aggregates):
            if result.status == CHECK_SUCCESS:
                continue
            if result.status == "skipped":
                continue
            reports.append(result.report or f"{result.check_name} status={result.status}")
        return reports


def hours(n):
    return T0 + timedelta(hours=n)
