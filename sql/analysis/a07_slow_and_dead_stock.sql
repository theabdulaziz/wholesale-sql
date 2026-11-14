-- Question: which products that used to sell have stopped?
-- Technique: date arithmetic against a fixed as-of date, plus a check against the
--            same window one year earlier so seasonal lines are not mistaken for dead ones.
-- The dataset has no stock-on-hand figures, so this finds products with no recent
-- demand. Whether stock is actually sitting in the warehouse has to be checked there.

create or replace view analysis.slow_and_dead_stock as
with p as (select as_of_date from params),
activity as (
    select
        s.stock_code,
        max(s.invoice_date) filter (where not s.is_return)                                  as last_sale_date,
        sum(s.amount)   filter (where s.invoice_date >  p.as_of_date - interval 455 day
                                  and s.invoice_date <= p.as_of_date - interval 90 day)     as revenue_prior_12m,
        sum(s.quantity) filter (where s.invoice_date >  p.as_of_date - interval 455 day
                                  and s.invoice_date <= p.as_of_date - interval 90 day)     as units_prior_12m,
        coalesce(sum(s.quantity) filter (where not s.is_return
                                  and s.invoice_date >  p.as_of_date - interval 455 day
                                  and s.invoice_date <= p.as_of_date - interval 365 day), 0) as units_same_window_last_year
    from fact_sales s cross join p
    group by s.stock_code
)
select
    a.stock_code,
    d.product_name,
    a.last_sale_date,
    date_diff('day', a.last_sale_date, p.as_of_date)        as days_since_last_sale,
    case when date_diff('day', a.last_sale_date, p.as_of_date) > 180 then 'dead (no sale in 180+ days)'
         else 'slow (no sale in 90-180 days)' end           as status,
    a.units_prior_12m,
    a.revenue_prior_12m,
    a.units_same_window_last_year,
    -- It also sold nothing in these same 90 days a year ago, yet sold afterwards.
    a.units_same_window_last_year = 0                       as possibly_seasonal
from activity a
cross join p
left join dim_product d using (stock_code)
where a.last_sale_date is not null
  and date_diff('day', a.last_sale_date, p.as_of_date) > 90
  and coalesce(a.revenue_prior_12m, 0) > 0
order by a.revenue_prior_12m desc;
