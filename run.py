"""Build the database, run every analysis, export results and write FINDINGS.md.

    python run.py

Needs data/raw/online_retail_ii.csv (see scripts/get_data.py).
"""

from __future__ import annotations

import sys
import time
from pathlib import Path

import duckdb

ROOT = Path(__file__).parent
RAW = ROOT / "data" / "raw" / "online_retail_ii.csv"
DB = ROOT / "build" / "retail.duckdb"
RESULTS = ROOT / "results"

# Per-entity views are long; export the top rows only. Summaries are exported whole.
ROW_LIMITS = {
    "rfm_customers": 100, "churn_risk": 100, "abc_xyz_products": 100, "slow_and_dead_stock": 100,
    "stock_adjustments_classified": 0, "returns_by_product": 50, "reorder_signals": 100, "basket_pairs": 50, "reversed_orders": 50,
}


def build(db_path: Path = DB) -> duckdb.DuckDBPyConnection:
    if not RAW.exists():
        sys.exit(f"Missing {RAW.relative_to(ROOT)}. Run: python scripts/get_data.py")
    db_path.parent.mkdir(exist_ok=True)
    if db_path.exists():
        db_path.unlink()
    con = duckdb.connect(str(db_path))
    con.execute(f"set file_search_path = '{ROOT.as_posix()}'")
    for path in sorted((ROOT / "sql").glob("*.sql")) + sorted((ROOT / "sql" / "analysis").glob("*.sql")):
        started = time.perf_counter()
        con.execute(path.read_text(encoding="utf-8"))
        print(f"  {path.relative_to(ROOT).as_posix():45s} {time.perf_counter() - started:5.2f}s")
    return con


def export(con: duckdb.DuckDBPyConnection) -> None:
    RESULTS.mkdir(exist_ok=True)
    views = [r[0] for r in con.execute(
        "select table_name from information_schema.tables where table_schema = 'analysis' order by 1").fetchall()]
    for view in views:
        limit = ROW_LIMITS.get(view)
        if limit == 0:
            continue
        clause = f" limit {limit}" if limit else ""
        con.execute(f"copy (select * from analysis.{view}{clause}) to '{(RESULTS / (view + '.csv')).as_posix()}' (header, delimiter ',')")
    print(f"  exported {len([v for v in views if ROW_LIMITS.get(v) != 0])} result files to results/")


if __name__ == "__main__":
    print("Building database")
    connection = build()
    export(connection)
    from findings import write_findings

    write_findings(connection, ROOT / "FINDINGS.md")
    print("  wrote FINDINGS.md")
