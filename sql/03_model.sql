-- 03_model.sql
-- A small star schema over the classified lines.

-- Parameters used across the analyses, in one place.
create or replace table params as
select
    cast(max(invoice_ts) as date)   as as_of_date,        -- "today" for this dataset
    2                               as lead_time_weeks,   -- assumed supplier lead time
    1.65                            as service_z          -- z-score for a 95% service level
from stg.lines;

create or replace table fact_sales as
select
    row_id,
    invoice,
    invoice_ts,
    cast(invoice_ts as date)        as invoice_date,
    stock_code,
    customer_id,                    -- null = guest checkout, no account
    country,
    quantity,                       -- negative on returns
    unit_price,
    amount,                         -- negative on returns
    line_type = 'return'            as is_return,
    is_repeat_line
from stg.lines
where line_type in ('sale', 'return');

create or replace table fact_stock_adjustments as
select
    row_id,
    invoice,
    cast(invoice_ts as date)        as adjustment_date,
    stock_code,
    quantity,                       -- negative = stock written off, positive = stock found
    description                     as note
from stg.lines
where line_type = 'stock_adjustment';

create or replace table fact_charges as
select row_id, invoice, cast(invoice_ts as date) as charge_date, stock_code as charge_code,
       description, customer_id, country, quantity, unit_price, amount, line_type
from stg.lines
where line_type in ('charge', 'gift_voucher');

create or replace table dim_product as
select
    stock_code,
    -- The most common description used when the product was actually sold.
    coalesce(mode(description) filter (where line_type = 'sale'), mode(description)) as product_name,
    min(cast(invoice_ts as date)) filter (where line_type = 'sale')    as first_sale_date,
    max(cast(invoice_ts as date)) filter (where line_type = 'sale')    as last_sale_date,
    coalesce(sum(quantity) filter (where line_type = 'sale'), 0)       as units_sold,
    cast(sum(amount) filter (where line_type = 'sale')
         / nullif(sum(quantity) filter (where line_type = 'sale'), 0) as decimal(12, 3)) as avg_unit_price
from stg.lines
where is_product_code and stock_code not like 'TEST%'
group by stock_code;

create or replace table dim_customer as
select
    customer_id,
    arg_max(country, invoice_ts)                        as country,       -- most recent
    min(invoice_date) filter (where not is_return)      as first_order_date,
    max(invoice_date) filter (where not is_return)      as last_order_date,
    count(distinct invoice) filter (where not is_return) as orders,
    sum(amount)                                         as net_revenue
from fact_sales
where customer_id is not null
group by customer_id;

create or replace table dim_date as
select
    d::date                                 as date,
    year(d)                                 as year,
    month(d)                                as month,
    date_trunc('month', d)::date            as month_start,
    date_trunc('week', d)::date             as week_start,
    dayname(d)                              as day_name,
    isodow(d) in (6, 7)                     as is_weekend
from generate_series(
    (select min(invoice_date) from fact_sales),
    (select max(invoice_date) from fact_sales),
    interval 1 day
) as t(d);
