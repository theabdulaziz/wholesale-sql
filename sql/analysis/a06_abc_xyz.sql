-- Question: which products matter most, and how predictable is their demand?
-- Technique: ABC by cumulative revenue share (running SUM), XYZ by the coefficient
--            of variation of monthly demand, with zero-sales months filled in.
-- Window: the last 12 complete months.

create or replace view analysis.abc_xyz_products as
with bounds as (
    select date_trunc('month', as_of_date)::date - interval 12 month as start_month,
           date_trunc('month', as_of_date)::date                     as end_month   -- exclusive
    from params
),
months as (
    select distinct month_start from dim_date, bounds
    where month_start >= start_month and month_start < end_month
),
sales as (
    select stock_code, date_trunc('month', invoice_date)::date as month_start,
           sum(quantity) as units, sum(amount) as revenue
    from fact_sales, bounds
    where invoice_date >= start_month and invoice_date < end_month
    group by 1, 2
),
products as (
    select stock_code, sum(revenue) as revenue, sum(units) as units
    from sales group by stock_code
    having sum(revenue) > 0 and sum(units) > 0
),
demand as (                                   -- one row per product per month, zeros included
    select p.stock_code, m.month_start, coalesce(s.units, 0) as units
    from products p
    cross join months m
    left join sales s on s.stock_code = p.stock_code and s.month_start = m.month_start
),
variability as (
    select stock_code, avg(units) as avg_monthly_units,
           stddev_pop(units) / nullif(avg(units), 0) as cv
    from demand group by stock_code
),
ranked as (
    select p.*,
           sum(p.revenue) over (order by p.revenue desc, p.stock_code) / sum(p.revenue) over () as cumulative_share
    from products p
)
select
    r.stock_code,
    d.product_name,
    r.revenue                                           as revenue_12m,
    r.units                                             as units_12m,
    round(100 * r.cumulative_share, 2)                  as cumulative_revenue_pct,
    case when r.cumulative_share - r.revenue / sum(r.revenue) over () < 0.80 then 'A'
         when r.cumulative_share - r.revenue / sum(r.revenue) over () < 0.95 then 'B'
         else 'C' end                                   as abc_class,
    round(v.avg_monthly_units, 1)                       as avg_monthly_units,
    round(v.cv, 2)                                      as demand_cv,
    case when v.cv < 0.5 then 'X' when v.cv < 1.0 then 'Y' else 'Z' end as xyz_class
from ranked r
join variability v using (stock_code)
left join dim_product d using (stock_code)
order by r.revenue desc;

create or replace view analysis.abc_xyz_matrix as
select
    abc_class,
    xyz_class,
    count(*)                                                    as products,
    sum(revenue_12m)                                            as revenue_12m,
    round(100.0 * sum(revenue_12m) / sum(sum(revenue_12m)) over (), 1) as pct_of_revenue
from analysis.abc_xyz_products
group by abc_class, xyz_class
order by abc_class, xyz_class;
