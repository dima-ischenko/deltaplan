-- Base volume: 100,000 customers, 1,000,000 orders, 30,000,000 order_items.
-- Then a delta of 7 per cent of the base: half of it updates existing keys, half inserts new rows.
-- The base watermark is written to deltaplan_watermark, so the tracker loads only the delta.
--
-- Install first: oracle/install.sql.
-- set serveroutput on size unlimited
-- set timing on

begin
    pkg_deltaplan_demo.load_base;
    pkg_deltaplan_demo.plant_delta(p_delta_pct => 7);
end;
/

-- A further wave, after the tracker has already run. updated_at will be later than the current maximum.
-- begin
--     pkg_deltaplan_demo.plant_delta(p_delta_pct => 10, p_update_share => 0.6);
-- end;
-- /

-- The same shape at a smaller scale: 1,000 customers, 10,000 orders, 300,000 items, a 7 per cent delta.
-- begin
--     pkg_deltaplan_demo.load_base(
--         p_customers => 1000,
--         p_orders => 10000,
--         p_items_per_order => 30
--     );
--     pkg_deltaplan_demo.plant_delta(p_delta_pct => 7);
-- end;
-- /
