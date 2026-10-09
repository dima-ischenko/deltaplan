create or replace package pkg_deltaplan_demo is

    -- 100,000 customers, 1,000,000 orders and 30 items each: 30,000,000 order_items.
    -- The base updated_at is 2024-01-15 10:00:00.
    -- When p_mark_synced is true, that instant is written to deltaplan_watermark,
    -- so the next run loads only the delta planted afterwards.
    procedure load_base(
        p_customers       number  default 100000,
        p_orders          number  default 1000000,
        p_items_per_order number  default 30,
        p_mark_synced     boolean default true
    );

    -- Plants a delta on top of load_base.
    -- Some existing keys are updated; some customers, orders and items are inserted.
    -- p_delta_pct is the share of the base volume, from 5 to 10.
    -- p_update_share is the fraction of that delta which is an update; the rest is inserted.
    -- A further call adds another wave with a later updated_at.
    procedure plant_delta(
        p_delta_pct    number default 7,
        p_update_share number default 0.5,
        p_as_of        date   default null
    );

    procedure report;

end pkg_deltaplan_demo;
