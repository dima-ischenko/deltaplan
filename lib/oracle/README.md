# Oracle

Call `pkg_dpl` after you [deploy](deploy.md) it into the calculating user's schema.

The steps are the same as in the [root README](../../README.md): `initialize`, `capture_delta` for each source, the refresh statement, `finalize`.

## A run without batches

The merge reads `dpl_keys_tmp`, restricted to the current target and segment:

```sql
declare
    l_change_date date;
begin
    pkg_dpl.initialize('customer_metrics', 'all', 2);

    pkg_dpl.capture_delta('customers', q'[
        with changed_customers as (
            select id, updated_at
            from customers
            where updated_at > :since
        )
        select id as pk_1,
               updated_at as watermark
        from changed_customers
    ]');

    pkg_dpl.capture_delta('orders', q'[
        with changed_orders as (
            select customer_id, updated_at
            from orders
            where updated_at > :since
        )
        select customer_id as pk_1,
               max(updated_at) as watermark
        from changed_orders
        group by customer_id
    ]');

    pkg_dpl.capture_delta('order_items', q'[
        with changed_items as (
            select order_id, updated_at
            from order_items
            where updated_at > :since
        )
        select o.customer_id as pk_1,
               max(ci.updated_at) as watermark
        from changed_items ci
        join orders o on o.id = ci.order_id
        group by o.customer_id
    ]');

    l_change_date := sysdate;

    merge into customer_metrics t
        using (
            with changed as (
                select pk_1 as customer_id
                from dpl_keys_tmp
                where target_table = pkg_dpl.get_target_table
                  and data_segment = pkg_dpl.get_data_segment
                group by pk_1
            )
            select c.id as customer_id,
                   min(oi.quantity * oi.price * (1 - o.order_discount)) as min_amount,
                   max(oi.quantity * oi.price * (1 - o.order_discount)) as max_amount,
                   avg(oi.quantity * oi.price * (1 - o.order_discount)) as avg_amount,
                   count(case when o.status = 'completed' then 1 end) as cnt_completed
            from customers c
            join changed ch on ch.customer_id = c.id
            join orders o on o.customer_id = c.id
            join order_items oi on oi.order_id = o.id
            group by c.id
        ) s
        on (s.customer_id = t.customer_id)
        when matched then update set
            t.min_amount     = s.min_amount,
            t.max_amount     = s.max_amount,
            t.avg_amount     = s.avg_amount,
            t.cnt_completed  = s.cnt_completed,
            t.mt_change_date = l_change_date
        when not matched then insert (
            customer_id, min_amount, max_amount, avg_amount,
            cnt_completed, mt_change_date
        ) values (
            s.customer_id, s.min_amount, s.max_amount, s.avg_amount,
            s.cnt_completed, l_change_date
        );

    pkg_dpl.finalize;
    commit;
end;
```

## A run in batches

The merge is the same, except that it reads `dpl_batch_tmp` and does not filter on target or segment: those keys already belong to the open batch.

```sql
declare
    l_change_date date;
begin
    pkg_dpl.initialize('customer_metrics', 'all', 2);

    pkg_dpl.capture_delta('customers', q'[
        with changed_customers as (
            select id, updated_at
            from customers
            where updated_at > :since
        )
        select id as pk_1,
               updated_at as watermark
        from changed_customers
    ]');

    pkg_dpl.capture_delta('orders', q'[
        with changed_orders as (
            select customer_id, updated_at
            from orders
            where updated_at > :since
        )
        select customer_id as pk_1,
               max(updated_at) as watermark
        from changed_orders
        group by customer_id
    ]');

    pkg_dpl.capture_delta('order_items', q'[
        with changed_items as (
            select order_id, updated_at
            from order_items
            where updated_at > :since
        )
        select o.customer_id as pk_1,
               max(ci.updated_at) as watermark
        from changed_items ci
        join orders o on o.id = ci.order_id
        group by o.customer_id
    ]');

    l_change_date := sysdate;
    pkg_dpl.prepare_batches(5000);

    while pkg_dpl.next_batch loop
        merge into customer_metrics t
            using (
                with changed as (
                    select pk_1 as customer_id
                    from dpl_batch_tmp
                    group by pk_1
                )
                select c.id as customer_id,
                       min(oi.quantity * oi.price * (1 - o.order_discount)) as min_amount,
                       max(oi.quantity * oi.price * (1 - o.order_discount)) as max_amount,
                       avg(oi.quantity * oi.price * (1 - o.order_discount)) as avg_amount,
                       count(case when o.status = 'completed' then 1 end) as cnt_completed
                from customers c
                join changed ch on ch.customer_id = c.id
                join orders o on o.customer_id = c.id
                join order_items oi on oi.order_id = o.id
                group by c.id
            ) s
            on (s.customer_id = t.customer_id)
            when matched then update set
                t.min_amount     = s.min_amount,
                t.max_amount     = s.max_amount,
                t.avg_amount     = s.avg_amount,
                t.cnt_completed  = s.cnt_completed,
                t.mt_change_date = l_change_date
            when not matched then insert (
                customer_id, min_amount, max_amount, avg_amount,
                cnt_completed, mt_change_date
            ) values (
                s.customer_id, s.min_amount, s.max_amount, s.avg_amount,
                s.cnt_completed, l_change_date
            );

        pkg_dpl.finish_batch;
    end loop;

    pkg_dpl.finalize;
    commit;
end;
```

A session with three sources is in `demo/oracle/run.sql`. Start from [`demo/README.md`](../../demo/README.md). `demo/oracle/seed_volume.sql` loads a large source so the same `run.sql` can be timed against a delta.

## Commits

`prepare_batches` takes `p_commit_batch`, default true. When it is true, `finish_batch` commits that batch, and the target keeps those rows. `finalize` does not commit. The `commit` after `finalize` stores the watermark.

`p_commit_batch => false` leaves the whole run in one transaction. The caller commits once, after `finalize`.

When a task fails, the session ends. The open batch rolls back. Batches that already reached `finish_batch` stay in the target, and the watermark stays where it was. The next task repeats `initialize`, `capture_delta`, and the batch loop.

`finish_batch` records `sql%rowcount` of the preceding statement, so call it immediately after the refresh statement. Do not commit between `next_batch` and `finish_batch`: that commit empties `dpl_batch_tmp`.
