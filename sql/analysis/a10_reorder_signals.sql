-- Question: for the products that matter, at what stock level should we reorder?
-- Technique: weekly demand over the last 26 complete weeks (zero weeks filled in),
--            then reorder point = demand during lead time + safety stock,
--            safety stock = z * weekly std dev * sqrt(lead time).
-- Lead time and service level are assumptions held in the params table.
-- Limited to A and B class products, where a stock-out costs the most.

create or replace view analysis.reorder_signals as
with p as (select * from params),
bounds as (
    select date_trunc('week', as_of_date)::date - interval 26 week as start_week,
           date_trunc('week', as_of_date)::date                    as end_week      -- exclusive
    from p
),
weeks as (
    select distinct week_start from dim_date, bounds
    where week_start >= start_week and week_start < end_week
),
important as (
    select stock_code, product_name, abc_class, xyz_class
    from analysis.abc_xyz_products where abc_class in ('A', 'B')
),
weekly as (
    select stock_code, date_trunc('week', invoice_date)::date as week_start, sum(quantity) as units
    from fact_sales, bounds
    where invoice_date >= start_week and invoice_date < end_week
    group by 1, 2
),
demand as (
    select i.stock_code, w.week_start, greatest(coalesce(k.units, 0), 0) as units
    from important i
    cross join weeks w
    left join weekly k on k.stock_code = i.stock_code and k.week_start = w.week_start
),
stats as (
    select stock_code, avg(units) as avg_weekly_units, stddev_samp(units) as sd_weekly_units,
           count(*) filter (where units = 0) as weeks_with_no_sales
    from demand group by stock_code
)
select
    i.stock_code,
    i.product_name,
    i.abc_class,
    i.xyz_class,
    round(s.avg_weekly_units, 1)                                            as avg_weekly_units,
    round(s.sd_weekly_units, 1)                                             as sd_weekly_units,
    s.weeks_with_no_sales,
    ceil(p.service_z * s.sd_weekly_units * sqrt(p.lead_time_weeks))         as safety_stock_units,
    ceil(s.avg_weekly_units * p.lead_time_weeks
         + p.service_z * s.sd_weekly_units * sqrt(p.lead_time_weeks))       as reorder_point_units
from important i
join stats s using (stock_code)
cross join p
where s.avg_weekly_units > 0
order by s.avg_weekly_units desc;
