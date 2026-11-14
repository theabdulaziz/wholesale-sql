"""Write FINDINGS.md from the analysis views, so every number in it is reproducible."""

from __future__ import annotations

from pathlib import Path

import duckdb


def _one(con, sql: str):
    return con.execute(sql).fetchone()


def _md_table(con, sql: str) -> str:
    cur = con.execute(sql)
    cols = [d[0] for d in cur.description]
    rows = cur.fetchall()

    def fmt(v):
        if v is None:
            return ""
        if isinstance(v, bool):
            return "yes" if v else "no"
        if isinstance(v, int):
            return f"{v:,}"
        if hasattr(v, "is_integer") or v.__class__.__name__ == "Decimal":
            f = float(v)
            return f"{f:,.0f}" if abs(f) >= 1000 else (f"{f:,.1f}" if f != int(f) else f"{f:,.0f}")
        return str(v)

    out = ["| " + " | ".join(c.replace("_", " ") for c in cols) + " |", "|" + "---|" * len(cols)]
    out += ["| " + " | ".join(fmt(v) for v in r) + " |" for r in rows]
    return "\n".join(out)


def write_findings(con: duckdb.DuckDBPyConnection, path: Path) -> None:
    raw_rows, = _one(con, "select count(*) from raw.online_retail")
    gross, returns, net, orders, customers, products, first, last, guest = _one(con, """
        select sum(amount) filter (where not is_return), -sum(amount) filter (where is_return), sum(amount),
               count(distinct invoice) filter (where not is_return), count(distinct customer_id),
               count(distinct stock_code), min(invoice_date), max(invoice_date),
               sum(amount) filter (where customer_id is null)
        from fact_sales""")
    sale_rows, non_sale_rows = _one(con, """
        select sum(raw_rows) filter (where line_type = 'sale'), sum(raw_rows) filter (where line_type <> 'sale')
        from analysis.data_quality_report""")
    repeat_rows, repeat_amt = _one(con, "select count(*), sum(amount) from stg.lines where is_repeat_line and line_type = 'sale'")
    charges, = _one(con, "select sum(amount) from fact_charges where line_type = 'charge'")

    top_decile_pct, top_decile_n = _one(con, """
        select cumulative_pct_of_account_revenue, customers from analysis.customer_concentration where decile = 1""")
    top5_pct, = _one(con, """
        with c as (select customer_id, sum(amount) r from fact_sales where customer_id is not null group by 1)
        select round(100.0 * sum(r) filter (where rk <= 5) / sum(r), 1) from (select *, row_number() over (order by r desc) rk from c)""")
    champ_c, champ_r = _one(con, "select pct_of_customers, pct_of_revenue from analysis.rfm_segments where segment = 'Champions'")
    risk_n, risk_rev = _one(con, "select count(*), sum(revenue_last_12m) from analysis.churn_risk")
    ret_m1, ret_m12 = _one(con, """
        select round(sum(customers) filter (where months_since_first_order = 1) * 100.0
                     / sum(cohort_size) filter (where months_since_first_order = 1), 1),
               round(sum(customers) filter (where months_since_first_order = 12) * 100.0
                     / sum(cohort_size) filter (where months_since_first_order = 12), 1)
        from analysis.cohort_retention where cohort_month > (select min(cohort_month) from analysis.cohort_retention)""")

    a_n, a_pct, all_n = _one(con, """
        select count(*) filter (where abc_class = 'A'),
               round(100.0 * sum(revenue_12m) filter (where abc_class = 'A') / sum(revenue_12m), 1), count(*)
        from analysis.abc_xyz_products""")
    az_n, az_pct = _one(con, "select products, pct_of_revenue from analysis.abc_xyz_matrix where abc_class = 'A' and xyz_class = 'Z'")
    dead_n, dead_rev = _one(con, """
        select count(*), sum(revenue_prior_12m) from analysis.slow_and_dead_stock
        where status like 'dead%' and not possibly_seasonal""")
    slow_n, slow_rev = _one(con, """
        select count(*), sum(revenue_prior_12m) from analysis.slow_and_dead_stock
        where status like 'slow%' and not possibly_seasonal""")
    seasonal_n, = _one(con, "select count(*) from analysis.slow_and_dead_stock where possibly_seasonal")
    wo_units, wo_back, wo_value, wo_noreason = _one(con, """
        select sum(units_written_off), sum(units_added_back), sum(est_selling_value_written_off),
               round(100.0 * sum(units_written_off) filter (where reason = 'no reason recorded') / sum(units_written_off), 0)
        from analysis.stock_writeoffs_by_reason""")
    rev_n, rev_value, rev_same_day = _one(con, """
        select count(*), sum(value), sum(value) filter (where days_to_reversal = 0) from analysis.reversed_orders""")
    disc_100, units_100, lines_100 = _one(con, """
        select discount_vs_small_order_pct, pct_of_units, pct_of_lines from analysis.volume_pricing where quantity_band like '4.%'""")
    pair = _one(con, "select name_a, name_b, lift, pct_of_a_baskets_with_b from analysis.basket_pairs order by lift desc limit 1")
    peak = _one(con, """
        select strftime(month, '%B %Y'), net_revenue from analysis.monthly_revenue where not is_partial_month
        order by net_revenue desc limit 1""")
    nov_share, = _one(con, """
        select round(100.0 * sum(net_revenue) filter (where month(month) in (9, 10, 11))
                     / sum(net_revenue), 1)
        from analysis.monthly_revenue where month >= date '2010-12-01' and month < date '2011-12-01'""")

    text = f"""# Findings

Generated by `python run.py` from the Online Retail II dataset: {raw_rows:,} raw invoice lines from a UK
online retailer selling giftware, much of it to wholesale customers, between {first} and {last}.
All amounts are in pounds sterling. Every number below comes from a view in the `analysis` schema.

## 1. The raw file is not all sales

Only {sale_rows:,} of the {raw_rows:,} raw rows ({100 * sale_rows / raw_rows:.1f}%) are product sales. The other
{non_sale_rows:,} are returns, postage and fees, stock adjustments, vouchers, free items and test rows.
Each row is labelled, none is deleted, and the categories add back to the raw row count.

{_md_table(con, "select line_type, raw_rows, pct_of_rows, round(amount) as amount, repeat_lines from analysis.data_quality_report")}

- Non-product charges (postage, marketplace fees, bad debt write-offs, manual adjustments) net to {float(charges):,.0f}.
  Left in, they would be mistaken for product revenue.
- {repeat_rows:,} sale lines repeat another line on the same invoice exactly, worth {float(repeat_amt):,.0f}
  ({100 * float(repeat_amt) / float(gross):.1f}% of gross sales). They may be genuine repeat scans, so they are flagged
  (`is_repeat_line`) and kept. Revenue would be at most that much lower if they are errors.

## 2. Revenue

Gross product sales were {float(gross):,.0f} across {orders:,} orders, returns {float(returns):,.0f}, net {float(net):,.0f}.
The business is strongly seasonal: September to November brought in {nov_share}% of a year's net revenue,
and the best month was {peak[0]} at {float(peak[1]):,.0f}. The last month in the file is partial and is flagged.

**Most "returns" are not returns.** {rev_n:,} credit lines exactly reverse an earlier sale to the same customer
(same product, quantity and price). They total {float(rev_value):,.0f}, which is {100 * float(rev_value) / float(returns):.0f}% of all
return value, and {float(rev_same_day):,.0f} of it was reversed the same day. Two orders alone, each keyed in
and cancelled within twenty minutes, account for {float(_one(con, "select sum(value) from (select value from analysis.reversed_orders order by value desc limit 2)")[0]):,.0f}.
Gross sales and return rates should be read net of these.

## 3. Customers

- **Concentration.** The largest 10% of accounts ({top_decile_n:,} customers) generate {top_decile_pct}% of account revenue.
  The top five accounts alone are {top5_pct}%.
- **Guest checkouts** (no customer account) are {100 * float(guest) / float(net):.1f}% of net revenue and cannot be tracked.
- **RFM.** "Champions" are {champ_c}% of customers and {champ_r}% of revenue.
- **Retention.** Leaving out the first cohort (which includes every customer who existed before the data starts),
  {ret_m1}% of new customers order again in the following month and {ret_m12}% are active twelve months later.
- **Customers gone quiet.** {risk_n:,} regular customers have been silent for at least twice their own usual gap
  between orders. They spent {float(risk_rev):,.0f} in the last twelve months.

{_md_table(con, "select segment, customers, pct_of_customers, pct_of_revenue, median_recency_days, median_orders from analysis.rfm_segments")}

## 4. Products and stock

- **ABC.** {a_n:,} of {all_n:,} products ({100 * a_n / all_n:.0f}%) produce {a_pct}% of the last twelve months' revenue.
- **Important but unpredictable.** {az_n:,} A-class products have erratic monthly demand (class AZ). They are
  {az_pct}% of revenue and the hardest to keep in stock without over-buying.
- **Stopped selling.** {dead_n:,} products that earned {float(dead_rev):,.0f} in the prior year have not sold in over
  180 days, and another {slow_n:,} (prior-year revenue {float(slow_rev):,.0f}) not in 90 to 180 days. A further
  {seasonal_n:,} quiet products also sold nothing in the same window last year and are probably seasonal.
- **Stock adjustments.** Warehouse adjustments took {int(wo_units):,} units out of stock (roughly {float(wo_value):,.0f} at
  selling price) and put {int(wo_back):,} back. {int(wo_noreason)}% of the units taken out have no reason recorded,
  so the true split between damage, loss and simple recounts cannot be known from the system.

{_md_table(con, "select abc_class, xyz_class, products, round(revenue_12m) as revenue_12m, pct_of_revenue from analysis.abc_xyz_matrix")}

{_md_table(con, "select reason, adjustment_lines, units_written_off, est_selling_value_written_off from analysis.stock_writeoffs_by_reason")}

## 5. Pricing and baskets

- **The wholesale discount is large.** Lines of 100 or more units are {lines_100}% of order lines but {units_100}% of
  units, at {disc_100}% below the per-unit price paid on small orders.
- **Bought together.** The strongest pairing is "{pair[0]}" with "{pair[1]}": {pair[3]}% of baskets with the first
  also contain the second, {pair[2]:.0f} times more often than chance.

{_md_table(con, "select quantity_band, pct_of_lines, pct_of_units, pct_of_revenue, discount_vs_small_order_pct from analysis.volume_pricing")}

## What the data cannot say

- There are no cost prices, so there is no margin analysis and write-offs are valued at selling price.
- There are no stock-on-hand figures. "Stopped selling" means no recent demand, not confirmed idle stock.
- Reorder points use an assumed two-week lead time and 95% service level, set in the `params` table.
- The dataset ends in December 2011. The method is current; the figures are historical.
"""
    path.write_text(text, encoding="utf-8")
