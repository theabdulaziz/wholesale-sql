"""Download the Online Retail II dataset and save it as data/raw/online_retail_ii.csv.

    python scripts/get_data.py

Source: Chen, D. (2012). Online Retail II. UCI Machine Learning Repository.
https://doi.org/10.24432/C5CG6D

The file is fetched from the `onlineretail2` R package on GitHub, which carries the
same 1,067,371 rows with the donor's permission. The data is not committed to this
repository. If you already have the UCI spreadsheet, export both sheets to one CSV
with the columns Invoice, StockCode, Description, Quantity, InvoiceDate, Price,
CustomerID, Country and place it at the path above instead.
"""

from __future__ import annotations

import sys
import tempfile
import urllib.request
from pathlib import Path

URL = "https://raw.githubusercontent.com/allanvc/onlineretail2/master/data/onlineretail2.rda"
OUT = Path(__file__).resolve().parent.parent / "data" / "raw" / "online_retail_ii.csv"
EXPECTED_ROWS = 1_067_371


def main() -> int:
    try:
        import pyreadr
    except ImportError:
        print("Install the requirements first: pip install -r requirements.txt", file=sys.stderr)
        return 1
    if OUT.exists():
        print(f"{OUT} already exists; delete it to download again.")
        return 0
    OUT.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory() as tmp:
        rda = Path(tmp) / "onlineretail2.rda"
        print("Downloading (about 11 MB)...")
        urllib.request.urlretrieve(URL, rda)
        frame = next(iter(pyreadr.read_r(str(rda)).values()))
    if len(frame) != EXPECTED_ROWS:
        print(f"warning: expected {EXPECTED_ROWS:,} rows, got {len(frame):,}", file=sys.stderr)
    frame.to_csv(OUT, index=False, date_format="%Y-%m-%d %H:%M:%S")
    print(f"Wrote {len(frame):,} rows to {OUT}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
