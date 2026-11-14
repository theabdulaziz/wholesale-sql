-- Question: how dependent is the business on its biggest accounts?
-- Technique: NTILE deciles and a running total for the Pareto curve.
-- Guest checkouts (no customer id) are shown as their own row, decile 0.

create or replace view analysis.customer_concentration as
with by_customer as (
    select customer_id, sum(amount) as net_revenue
    from fact_sales
    where customer_id is not null
    group by customer_id
),
ranked as (
    select *, ntile(10) over (order by net_revenue desc, customer_id) as decile
    from by_customer
),
deciles as (
    select decile, count(*) as customers, sum(net_revenue) as net_revenue,
           min(net_revenue) as smallest_account, max(net_revenue) as largest_account
    from ranked
    group by decile
    union all
    select 0, null, sum(amount), null, null
    from fact_sales
    where customer_id is null
),
total as (select sum(net_revenue) as all_revenue from deciles)
select
    decile,
    case when decile = 0 then 'Guest checkout (no account)'
         when decile = 1 then 'Decile 1 (largest 10% of accounts)'
         when decile = 10 then 'Decile 10 (smallest 10% of accounts)'
         else 'Decile ' || decile end                               as label,
    customers,
    net_revenue,
    round(100.0 * net_revenue / all_revenue, 1)                     as pct_of_all_revenue,
    case when decile > 0 then
        round(100.0 * sum(net_revenue) filter (where decile > 0) over (order by decile)
              / sum(net_revenue) filter (where decile > 0) over (), 1)
    end                                                             as cumulative_pct_of_account_revenue,
    smallest_account,
    largest_account
from deciles, total
order by decile;
