-- Question: which customers deserve attention, and what kind?
-- Technique: recency / frequency / monetary scoring with NTILE(5), then named segments.

create or replace view analysis.rfm_customers as
with base as (
    select
        customer_id,
        date_diff('day', max(invoice_date) filter (where not is_return), (select as_of_date from params)) as recency_days,
        count(distinct invoice) filter (where not is_return)   as frequency,
        sum(amount)                                             as monetary
    from fact_sales
    where customer_id is not null
    group by customer_id
    having count(*) filter (where not is_return) > 0
),
scored as (
    select *,
        ntile(5) over (order by recency_days desc, customer_id) as r,   -- 5 = bought most recently
        ntile(5) over (order by frequency, customer_id)         as f,
        ntile(5) over (order by monetary, customer_id)          as m
    from base
)
select
    *,
    case
        when r >= 4 and f >= 4 then 'Champions'
        when r >= 3 and f >= 3 then 'Loyal'
        when r >= 4            then 'New or promising'
        when r <= 2 and f >= 4 then 'At risk, was frequent'
        when r <= 2 and f <= 2 then 'Lapsed'
        else                        'Needs attention'
    end as segment
from scored;

create or replace view analysis.rfm_segments as
select
    segment,
    count(*)                                                as customers,
    round(100.0 * count(*) / sum(count(*)) over (), 1)      as pct_of_customers,
    sum(monetary)                                           as net_revenue,
    round(100.0 * sum(monetary) / sum(sum(monetary)) over (), 1) as pct_of_revenue,
    round(median(recency_days))                             as median_recency_days,
    round(median(frequency))                                as median_orders,
    round(median(monetary), 2)                              as median_revenue
from analysis.rfm_customers
group by segment
order by net_revenue desc;
