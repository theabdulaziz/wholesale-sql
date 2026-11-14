-- Question: of the customers won in a given month, how many are still buying later?
-- Technique: cohort assignment with MIN() OVER, a self-relative month index,
--            FIRST_VALUE to get the cohort size.

create or replace view analysis.cohort_retention as
with orders as (
    select distinct customer_id, date_trunc('month', invoice_date)::date as order_month
    from fact_sales
    where customer_id is not null and not is_return
),
cohorts as (
    select customer_id, order_month,
           min(order_month) over (partition by customer_id) as cohort_month
    from orders
),
counts as (
    select cohort_month,
           date_diff('month', cohort_month, order_month) as months_since_first_order,
           count(*) as customers
    from cohorts
    group by 1, 2
)
select
    cohort_month,
    months_since_first_order,
    customers,
    first_value(customers) over (partition by cohort_month order by months_since_first_order) as cohort_size,
    round(100.0 * customers
          / first_value(customers) over (partition by cohort_month order by months_since_first_order), 1) as retention_pct
from counts
where months_since_first_order <= 12
order by cohort_month, months_since_first_order;
