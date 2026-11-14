-- Question: how much discount do bulk buyers actually get?
-- Technique: derive each product's small-order price, then measure every order line
--            against it by quantity band.
-- The data has no price list, so the baseline is the average price actually paid per
-- unit on lines of fewer than 6 units in the last 12 months. The first band is
-- therefore 0% by construction and the others show the discount relative to it.

create or replace view analysis.volume_pricing as
with recent as (
    select s.* from fact_sales s, params p
    where not s.is_return and s.invoice_date > p.as_of_date - interval 12 month
),
list_price as (
    select stock_code, sum(amount) / sum(quantity) as list_price
    from recent where quantity < 6
    group by stock_code
    having count(*) >= 20
),
banded as (
    select
        case when r.quantity < 6   then '1. 1-5 units'
             when r.quantity < 24  then '2. 6-23 units'
             when r.quantity < 100 then '3. 24-99 units'
             else                       '4. 100+ units' end as quantity_band,
        r.quantity, r.amount, r.quantity * l.list_price as amount_at_list
    from recent r join list_price l using (stock_code)
)
select
    quantity_band,
    count(*)                                                        as order_lines,
    round(100.0 * count(*) / sum(count(*)) over (), 1)              as pct_of_lines,
    sum(quantity)                                                   as units,
    round(100.0 * sum(quantity) / sum(sum(quantity)) over (), 1)    as pct_of_units,
    sum(amount)                                                     as revenue,
    round(100.0 * sum(amount) / sum(sum(amount)) over (), 1)        as pct_of_revenue,
    round(100.0 * (1 - sum(amount) / sum(amount_at_list)), 1)       as discount_vs_small_order_pct
from banded
group by quantity_band
order by quantity_band;
