-- Question: which products are bought together far more often than chance?
-- Technique: a self-join of invoice lines to count pairs, then support, confidence
--            and lift. Lift = how many times more often the pair occurs than it would
--            if the two products were bought independently.
-- Window: last 12 months. Thresholds keep the join small and the results meaningful.

create or replace view analysis.basket_pairs as
with baskets as (
    select distinct s.invoice, s.stock_code
    from fact_sales s, params p
    where not s.is_return and s.invoice_date > p.as_of_date - interval 12 month
),
n as (select count(distinct invoice) as invoices from baskets),
item_counts as (
    select stock_code, count(*) as invoices_with_item
    from baskets group by stock_code
    having count(*) >= 150
),
pairs as (
    select a.stock_code as product_a, b.stock_code as product_b, count(*) as invoices_with_both
    from baskets a
    join baskets b on a.invoice = b.invoice and a.stock_code < b.stock_code
    where a.stock_code in (select stock_code from item_counts)
      and b.stock_code in (select stock_code from item_counts)
    group by 1, 2
    having count(*) >= 100
)
select
    pr.product_a,
    da.product_name                                             as name_a,
    pr.product_b,
    db.product_name                                             as name_b,
    pr.invoices_with_both,
    round(100.0 * pr.invoices_with_both / n.invoices, 2)        as support_pct,
    round(100.0 * pr.invoices_with_both / ia.invoices_with_item, 1) as pct_of_a_baskets_with_b,
    round(100.0 * pr.invoices_with_both / ib.invoices_with_item, 1) as pct_of_b_baskets_with_a,
    round(pr.invoices_with_both * n.invoices::double
          / (ia.invoices_with_item * ib.invoices_with_item), 1) as lift
from pairs pr
cross join n
join item_counts ia on ia.stock_code = pr.product_a
join item_counts ib on ib.stock_code = pr.product_b
left join dim_product da on da.stock_code = pr.product_a
left join dim_product db on db.stock_code = pr.product_b
order by lift desc;
