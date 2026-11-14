-- Question: which products come back most, by rate and by value?
-- Technique: conditional aggregation with a volume threshold, so a product that sold
--            two units and had one returned does not top the list.

create or replace view analysis.returns_by_product as
select
    s.stock_code,
    d.product_name,
    sum(s.quantity) filter (where not s.is_return)              as units_sold,
    -coalesce(sum(s.quantity) filter (where s.is_return), 0)    as units_returned,
    round(-100.0 * coalesce(sum(s.quantity) filter (where s.is_return), 0)
          / sum(s.quantity) filter (where not s.is_return), 1)  as return_rate_pct,
    -coalesce(sum(s.amount) filter (where s.is_return), 0)      as value_returned,
    count(distinct s.customer_id) filter (where s.is_return)    as customers_returning
from fact_sales s
left join dim_product d using (stock_code)
group by s.stock_code, d.product_name
having sum(s.quantity) filter (where not s.is_return) >= 500
   and coalesce(sum(s.quantity) filter (where s.is_return), 0) < 0
order by return_rate_pct desc;

-- Question: how much of "returns" is really an order keyed in and then cancelled?
-- Technique: match each credit line to the closest earlier sale line for the same
--            customer, product, quantity and price, using QUALIFY with ROW_NUMBER
--            so that each credit and each sale is used at most once.
-- These pairs inflate gross sales and returns equally and say nothing about product quality.

create or replace view analysis.reversed_orders as
with credits as (
    select * from fact_sales where is_return and customer_id is not null
),
sales as (
    select * from fact_sales where not is_return and customer_id is not null
),
candidates as (
    select
        c.row_id as credit_row, s.row_id as sale_row,
        c.customer_id, c.stock_code,
        s.invoice as sale_invoice, s.invoice_ts as sale_ts,
        c.invoice as credit_invoice, c.invoice_ts as credit_ts,
        s.quantity as units, s.amount as value
    from credits c
    join sales s
      on  s.customer_id = c.customer_id
      and s.stock_code  = c.stock_code
      and s.quantity    = -c.quantity
      and s.unit_price  = c.unit_price
      and s.invoice_ts <= c.invoice_ts
    qualify row_number() over (partition by c.row_id order by s.invoice_ts desc, s.row_id desc) = 1
)
select
    m.customer_id, m.stock_code, d.product_name,
    m.sale_invoice, m.sale_ts, m.credit_invoice, m.credit_ts,
    date_diff('day', cast(m.sale_ts as date), cast(m.credit_ts as date)) as days_to_reversal,
    m.units, m.value
from candidates m
left join dim_product d using (stock_code)
qualify row_number() over (partition by m.sale_row order by m.credit_ts, m.credit_row) = 1
order by m.value desc;
