# Wholesale sales and stock analysis in SQL

Twelve business questions answered in SQL on a real dataset of 1,067,371 invoice lines from a UK online retailer that sells giftware, much of it to wholesalers, over two years (December 2009 to December 2011).

The whole pipeline is SQL: load, clean, model, analyse. Python is used only to run the files in order and export the results. It runs on DuckDB, so there is no database server to install, and a full build takes under ten seconds.

**Read the results first:** [FINDINGS.md](FINDINGS.md)

## What it found

| | |
|---|---|
| **75% of "returns" are not returns** | 5,984 credit lines exactly reverse an earlier sale (same customer, product, quantity and price), worth 541,848 of the 726,556 returned. Two orders keyed in and cancelled within twenty minutes account for 245,653. |
| **Revenue depends on a few accounts** | The largest 10% of accounts (588 customers) bring in 63.4% of account revenue. |
| **Bulk buyers pay about a third less** | Lines of 100+ units are 1.2% of order lines but 27.5% of units, at 36.3% below the small-order price. |
| **787 products have stopped selling** | 613 have had no sale in 180+ days and 174 in 90 to 180 days, after earning 436,755 between them the year before. Likely-seasonal lines are separated out. |
| **586 regular customers have gone quiet** | Each silent for at least twice their own usual gap between orders; they spent 484,781 in the last twelve months. |
| **45% of stock taken out has no reason recorded** | 568,077 units were removed by warehouse adjustments. Free-text notes ("damaged", "?", "thrown away") are grouped into reasons with regular expressions. |
| **The raw file is not all sales** | 30,350 rows are returns, postage, marketplace fees, bad debt, stock adjustments, vouchers and test rows. Every row is labelled and the categories add back to the raw count. |

All amounts are in pounds sterling.

## Run it

```bash
pip install -r requirements.txt
python scripts/get_data.py      # downloads the dataset (about 11 MB) to data/raw/
python run.py                   # builds build/retail.duckdb, writes results/ and FINDINGS.md
pytest                          # 17 reconciliation tests
```

To explore the database yourself:

```bash
python -c "import duckdb; print(duckdb.connect('build/retail.duckdb').sql('select * from analysis.rfm_segments'))"
```

## How it is organised

```
sql/
  01_load.sql              raw file landed as text, one row id per line
  02_clean.sql             types, and every row put in exactly one category
  03_model.sql             star schema: fact_sales, fact_stock_adjustments, fact_charges,
                           dim_product, dim_customer, dim_date, params
  04_quality_report.sql    where every raw row went
  analysis/                one file per business question
run.py                     runs the SQL in order, exports results
findings.py                writes FINDINGS.md from the views
tests/                     reconciliation tests
results/                   output of each analysis as CSV
```

### The cleaning rule that matters

Nothing is deleted. `02_clean.sql` gives each raw row one `line_type`:

| line_type | Rule | Rows |
|---|---|---:|
| `sale` | product code, price above zero, not a credit note | 1,037,021 |
| `return` | product line on a credit note (invoice starts with `C`) | 18,286 |
| `stock_adjustment` | product, price zero, no customer: damages, losses, recounts | 6,089 |
| `charge` | not a product: postage, fees, manual adjustments, bad debt | 5,795 |
| `gift_voucher` | voucher codes | 101 |
| `free_item` | product given to a customer at zero price | 62 |
| `test` | test product codes | 17 |

Lines that repeat another line on the same invoice exactly (33,664 sale lines, 2.3% of gross sales) are flagged and kept, because they cannot be shown to be errors.

## The twelve questions

| # | Question | View | SQL techniques |
|---|---|---|---|
| 1 | How is revenue trending and how much do returns take back? | `monthly_revenue` | `FILTER`, `LAG` for month-on-month and year-on-year, moving average window |
| 2 | How dependent is the business on its largest accounts? | `customer_concentration` | `NTILE`, running total for a Pareto curve |
| 3 | Do new customers come back? | `cohort_retention` | cohort assignment with `MIN() OVER`, `FIRST_VALUE` |
| 4 | Which customers deserve what kind of attention? | `rfm_customers`, `rfm_segments` | recency, frequency, monetary scoring with `NTILE(5)` |
| 5 | Which regulars have gone quiet for longer than is normal for them? | `churn_risk` | `LAG` for each customer's own order gaps, `MEDIAN` |
| 6 | Which products matter most and how predictable is their demand? | `abc_xyz_products`, `abc_xyz_matrix` | cumulative share, zero-filled demand via `CROSS JOIN`, coefficient of variation |
| 7 | Which products have stopped selling? | `slow_and_dead_stock` | date windows against an as-of date, same-window-last-year seasonality check |
| 8 | How much stock is written off, and why? | `stock_writeoffs_by_reason` | regular expressions over free-text notes |
| 9 | Which products come back, and how much of "returns" is cancelled orders? | `returns_by_product`, `reversed_orders` | `HAVING` thresholds, matching credits to sales with `QUALIFY ROW_NUMBER()` |
| 10 | At what stock level should the important products be reordered? | `reorder_signals` | weekly demand statistics, safety stock formula, parameters table |
| 11 | How much discount do bulk buyers actually get? | `volume_pricing` | inferred baseline price, quantity bands |
| 12 | Which products are bought together? | `basket_pairs` | self-join, support, confidence and lift |

Each SQL file opens with the question it answers and the assumptions it makes.

## Tests

The tests check that the numbers reconcile, on the real data:

- every raw row is classified exactly once, and the fact tables partition the classified lines
- total amount is unchanged by typing and cleaning
- monthly revenue and the concentration table both tie to the fact table
- cohorts start at 100% and cover every buyer; RFM gives every buyer exactly one segment
- ABC classes land on the 80% and 95% boundaries and never overlap in revenue
- no product on the dead-stock list has a sale in the last 90 days
- reorder points are never below lead-time demand; volume discounts rise with quantity

## Limits

- **No cost prices.** There is no margin analysis, and write-offs are valued at selling price.
- **No stock-on-hand figures.** "Stopped selling" means no recent demand. Whether stock is sitting idle has to be checked in the warehouse.
- **Assumptions.** Reorder points use a two-week lead time and a 95% service level, both set in the `params` table. Customer segments use common rule-of-thumb thresholds.
- **Inferred baseline price.** The data has no price list, so volume discounts are measured against the average price paid on orders of fewer than six units.
- **Historical data.** The dataset ends in December 2011.
- **DuckDB dialect.** `QUALIFY`, `FILTER` and `MODE` are used; most queries run on PostgreSQL with small changes.

## Data

Chen, D. (2012). *Online Retail II* [Dataset]. UCI Machine Learning Repository. https://doi.org/10.24432/C5CG6D

The data is not stored in this repository. `scripts/get_data.py` downloads it from the [`onlineretail2`](https://github.com/allanvc/onlineretail2) package, which distributes it with the donor's permission for non-commercial use. Check the UCI page for the terms that apply to your use.

## License

The code is MIT licensed. The dataset has its own terms, above.
