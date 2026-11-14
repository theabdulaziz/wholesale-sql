-- Question: how is the business trending, and how much do returns take back?
-- Technique: conditional aggregation, LAG for month-on-month and year-on-year,
--            a moving window for the 3-month average.

create or replace view analysis.monthly_revenue as
with monthly as (
    select
        date_trunc('month', invoice_date)::date                     as month,
        sum(amount) filter (where not is_return)                    as gross_sales,
        -coalesce(sum(amount) filter (where is_return), 0)          as returns,
        sum(amount)                                                 as net_revenue,
        count(distinct invoice) filter (where not is_return)        as orders,
        count(distinct customer_id)                                 as active_customers
    from fact_sales
    group by 1
)
select
    month,
    gross_sales,
    returns,
    round(100.0 * returns / gross_sales, 1)                         as return_pct,
    net_revenue,
    orders,
    active_customers,
    round(net_revenue / orders, 2)                                  as revenue_per_order,
    round(100.0 * (net_revenue / lag(net_revenue) over w - 1), 1)   as mom_pct,
    round(100.0 * (net_revenue / lag(net_revenue, 12) over w - 1), 1) as yoy_pct,
    round(avg(net_revenue) over (order by month rows between 2 preceding and current row), 2) as rolling_3m_avg,
    -- The data stops part-way through the last month.
    month = date_trunc('month', (select as_of_date from params))   as is_partial_month
from monthly
window w as (order by month)
order by month;
