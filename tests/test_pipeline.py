"""Reconciliation tests. They need the dataset: python scripts/get_data.py"""

import sys
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))
import run  # noqa: E402

pytestmark = pytest.mark.skipif(not run.RAW.exists(), reason="dataset not downloaded")


@pytest.fixture(scope="module")
def con(tmp_path_factory):
    connection = run.build(tmp_path_factory.mktemp("db") / "test.duckdb")
    yield connection
    connection.close()


def one(con, sql):
    return con.execute(sql).fetchone()[0]


# ------------------------------------------------------------------- cleaning
def test_every_raw_row_is_classified_exactly_once(con):
    raw = one(con, "select count(*) from raw.online_retail")
    assert raw == 1_067_371
    assert one(con, "select count(*) from stg.lines") == raw
    assert one(con, "select sum(raw_rows) from analysis.data_quality_report") == raw
    assert one(con, "select count(*) from stg.lines where line_type = 'unclassified'") == 0


def test_fact_tables_partition_the_classified_lines(con):
    parts = one(con, """
        select (select count(*) from fact_sales) + (select count(*) from fact_stock_adjustments)
             + (select count(*) from fact_charges)
             + (select count(*) from stg.lines where line_type in ('free_item', 'test'))""")
    assert parts == one(con, "select count(*) from stg.lines")


def test_amounts_survive_typing_unchanged(con):
    raw_total = one(con, "select sum(cast(Quantity as double) * cast(Price as double)) from raw.online_retail")
    assert float(one(con, "select sum(amount) from stg.lines")) == pytest.approx(raw_total, abs=0.01)


def test_sales_are_positive_and_returns_negative(con):
    assert one(con, "select count(*) from fact_sales where not is_return and (quantity <= 0 or unit_price <= 0)") == 0
    assert one(con, "select count(*) from fact_sales where is_return and amount > 0") == 0


def test_dimensions_cover_the_facts(con):
    assert one(con, "select count(*) from fact_sales s anti join dim_product p using (stock_code)") == 0
    assert one(con, """select count(*) from fact_sales s anti join dim_customer c using (customer_id)
                       where s.customer_id is not null""") == 0
    assert one(con, "select count(*) from dim_product") == one(con, "select count(distinct stock_code) from dim_product")


# ------------------------------------------------------------------- analyses
def test_monthly_revenue_ties_to_fact(con):
    assert one(con, "select sum(net_revenue) from analysis.monthly_revenue") == one(con, "select sum(amount) from fact_sales")
    assert one(con, "select count(*) from analysis.monthly_revenue where is_partial_month") == 1


def test_concentration_accounts_for_all_revenue(con):
    assert one(con, "select sum(net_revenue) from analysis.customer_concentration") == one(con, "select sum(amount) from fact_sales")
    assert float(one(con, "select max(cumulative_pct_of_account_revenue) from analysis.customer_concentration")) == 100.0


def test_cohorts_start_at_100_percent_and_never_exceed_it(con):
    assert one(con, "select count(*) from analysis.cohort_retention where months_since_first_order = 0 and retention_pct <> 100") == 0
    assert one(con, "select max(retention_pct) from analysis.cohort_retention") == 100
    buyers = one(con, "select count(distinct customer_id) from fact_sales where customer_id is not null and not is_return")
    assert one(con, "select sum(customers) from analysis.cohort_retention where months_since_first_order = 0") == buyers


def test_rfm_gives_every_buyer_one_segment(con):
    buyers = one(con, "select count(distinct customer_id) from fact_sales where customer_id is not null and not is_return")
    assert one(con, "select count(*) from analysis.rfm_customers") == buyers
    assert one(con, "select sum(customers) from analysis.rfm_segments") == buyers
    assert one(con, "select count(*) from analysis.rfm_customers where r not between 1 and 5 or f not between 1 and 5") == 0


def test_churn_list_only_contains_customers_silent_beyond_their_habit(con):
    assert one(con, "select count(*) from analysis.churn_risk") > 0
    assert one(con, "select min(silence_vs_habit) from analysis.churn_risk") >= 2
    assert one(con, "select min(order_days) from analysis.churn_risk") >= 4


def test_abc_classes_follow_the_80_95_rule(con):
    a, ab = con.execute("""
        select sum(revenue_12m) filter (where abc_class = 'A') / sum(revenue_12m),
               sum(revenue_12m) filter (where abc_class in ('A', 'B')) / sum(revenue_12m)
        from analysis.abc_xyz_products""").fetchone()
    assert 0.80 <= a < 0.81 and 0.95 <= ab < 0.96
    # A product in a better class never has less revenue than one in a worse class.
    assert one(con, "select min(revenue_12m) from analysis.abc_xyz_products where abc_class = 'A'") >= \
           one(con, "select max(revenue_12m) from analysis.abc_xyz_products where abc_class = 'B'")
    assert one(con, "select sum(products) from analysis.abc_xyz_matrix") == one(con, "select count(*) from analysis.abc_xyz_products")


def test_dead_stock_really_has_no_recent_sales(con):
    assert one(con, """
        select count(*) from analysis.slow_and_dead_stock d
        join fact_sales s using (stock_code), params p
        where not s.is_return and s.invoice_date > p.as_of_date - interval 90 day""") == 0


def test_writeoff_reasons_account_for_every_adjustment(con):
    assert one(con, "select sum(adjustment_lines) from analysis.stock_writeoffs_by_reason") == \
           one(con, "select count(*) from fact_stock_adjustments")


def test_reversed_orders_are_real_reversals_and_bounded_by_total_returns(con):
    assert one(con, "select count(*) from analysis.reversed_orders") > 0
    assert one(con, "select count(*) from analysis.reversed_orders where units <= 0 or value <= 0") == 0
    assert one(con, "select count(*) from analysis.reversed_orders where days_to_reversal < 0") == 0
    assert one(con, "select sum(value) from analysis.reversed_orders") <= -one(con, "select sum(amount) from fact_sales where is_return")


def test_reorder_point_is_never_below_lead_time_demand(con):
    assert one(con, """select count(*) from analysis.reorder_signals, params
                       where reorder_point_units < floor(avg_weekly_units * lead_time_weeks)""") == 0
    assert one(con, "select count(*) from analysis.reorder_signals where safety_stock_units < 0") == 0


def test_volume_bands_are_complete_and_discount_grows_with_quantity(con):
    rows = con.execute("select discount_vs_small_order_pct from analysis.volume_pricing order by quantity_band").fetchall()
    discounts = [float(r[0]) for r in rows]
    assert len(discounts) == 4 and discounts[0] == 0
    assert discounts == sorted(discounts)
    assert float(one(con, "select sum(pct_of_lines) from analysis.volume_pricing")) == pytest.approx(100, abs=0.2)


def test_basket_pairs_are_unordered_unique_and_above_threshold(con):
    assert one(con, "select count(*) from analysis.basket_pairs where product_a >= product_b") == 0
    assert one(con, "select count(*) from analysis.basket_pairs") == \
           one(con, "select count(distinct (product_a, product_b)) from analysis.basket_pairs")
    assert one(con, "select min(invoices_with_both) from analysis.basket_pairs") >= 100
    assert one(con, "select min(lift) from analysis.basket_pairs") > 0
