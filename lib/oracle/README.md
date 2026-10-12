# Oracle

Call `pkg_dpl` after you [deploy](deploy.md) it into the calculating user's schema. Methods and parameters: [root README](../../README.md).

Without batches, one refresh reads `dpl_keys_tmp` for the current target and segment. With batches, each refresh reads `dpl_batch_tmp`.

```sql
declare
    l_change_date date := sysdate;
begin
    pkg_dpl.initialize('customer_metrics', 'all', 2);

    pkg_dpl.capture_delta('customers', q'[
        select id as pk_1,
               updated_at as watermark
        from customers
        where updated_at > :since
    ]');

    pkg_dpl.capture_delta('orders', q'[
        select customer_id as pk_1,
               max(updated_at) as watermark
        from orders
        where updated_at > :since
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

    pkg_dpl.prepare_batches(5000);

    while pkg_dpl.next_batch loop
        merge into customer_metrics t
            using (
                with changed as (
                    select pk_1 as customer_id
                    from dpl_batch_tmp
                    group by pk_1
                ),
                order_amount as (
                    select c.id as customer_id,
                           o.id as order_id,
                           o.order_date,
                           o.status,
                           round(oi.quantity * oi.price * (1 - o.order_discount), 2) as amount
                    from customers c
                    join changed ch on ch.customer_id = c.id
                    join orders o on o.customer_id = c.id
                    join order_items oi on oi.order_id = o.id
                )
                select customer_id,
                       min(amount) as min_amount,
                       max(amount) as max_amount,
                       round(avg(amount), 2) as avg_amount,
                       max(order_id) keep (dense_rank last order by order_date) as last_order_id,
                       count(case when status = 'completed' then 1 end) as cnt_completed
                from order_amount
                group by customer_id
            ) s
            on (s.customer_id = t.customer_id)
            when matched then update set
                t.min_amount     = s.min_amount,
                t.max_amount     = s.max_amount,
                t.avg_amount     = s.avg_amount,
                t.last_order_id  = s.last_order_id,
                t.cnt_completed  = s.cnt_completed,
                t.mt_change_date = l_change_date
            where (decode(t.min_amount, s.min_amount, 0, 1) +
                   decode(t.max_amount, s.max_amount, 0, 1) +
                   decode(t.avg_amount, s.avg_amount, 0, 1) +
                   decode(t.last_order_id, s.last_order_id, 0, 1) +
                   decode(t.cnt_completed, s.cnt_completed, 0, 1)
                  ) > 0
            when not matched then insert (
                customer_id, min_amount, max_amount, avg_amount,
                last_order_id, cnt_completed, mt_change_date
            ) values (
                s.customer_id, s.min_amount, s.max_amount, s.avg_amount,
                s.last_order_id, s.cnt_completed, l_change_date
            );

        pkg_dpl.finish_batch;
    end loop;

    pkg_dpl.finalize;
    commit;
end;
```

The same script is `demo/oracle/run.sql`. See [`demo/README.md`](../../demo/README.md).

`finish_batch` commits when `p_commit_batch` is true (the default). `finalize` does not. Commit after `finalize` to store the watermark. `p_commit_batch => false` keeps the whole run in one transaction.
