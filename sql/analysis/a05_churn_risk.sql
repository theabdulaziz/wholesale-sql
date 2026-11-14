-- Question: which regular customers have gone quiet for longer than is normal *for them*?
-- Technique: LAG to get each customer's own gaps between orders, then compare the
--            current silence against their personal median gap.
-- A fixed "90 days inactive" rule misses a weekly buyer who stopped a month ago and
-- wrongly flags a customer who only ever orders twice a year.

create or replace view analysis.churn_risk as
with order_days as (
    select distinct customer_id, invoice_date
    from fact_sales
    where customer_id is not null and not is_return
),
gaps as (
    select customer_id, invoice_date,
           date_diff('day', lag(invoice_date) over (partition by customer_id order by invoice_date), invoice_date) as gap_days
    from order_days
),
habits as (
    select customer_id,
           count(*)                 as order_days,
           max(invoice_date)        as last_order_date,
           median(gap_days)         as median_gap_days
    from gaps
    group by customer_id
    having count(*) >= 4            -- enough history to have a habit
),
recent_value as (
    select customer_id, sum(amount) as revenue_last_12m
    from fact_sales, params
    where customer_id is not null
      and invoice_date > as_of_date - interval 12 month
    group by customer_id
)
select
    h.customer_id,
    c.country,
    h.order_days,
    h.last_order_date,
    date_diff('day', h.last_order_date, p.as_of_date)                               as days_silent,
    h.median_gap_days,
    round(date_diff('day', h.last_order_date, p.as_of_date) / h.median_gap_days, 1) as silence_vs_habit,
    coalesce(v.revenue_last_12m, 0)                                                 as revenue_last_12m
from habits h
cross join params p
join dim_customer c using (customer_id)
left join recent_value v using (customer_id)
where h.median_gap_days > 0
  and date_diff('day', h.last_order_date, p.as_of_date) >= 2 * h.median_gap_days
  and date_diff('day', h.last_order_date, p.as_of_date) > 30
order by revenue_last_12m desc;
