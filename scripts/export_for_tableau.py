"""Export the Tableau-facing marts to data/exports/*.csv.

Only aggregate marts and small dimensions are exported. The row-level facts
(fct_account_month, fct_payments) stay in DuckDB on purpose: they are large and the
dashboards are built entirely on the pre-aggregated marts.
"""

from __future__ import annotations

import argparse
import os
from pathlib import Path

import duckdb

# file name -> query against the warehouse
EXPORTS: dict[str, str] = {
    "mart_portfolio_kpis": "select * from marts.mart_portfolio_kpis order by statement_month, product_name",
    "mart_roll_rates": "select * from marts.mart_roll_rates order by transition_month, product_name, from_bucket_rank, to_bucket_rank",
    "mart_vintage_curves": "select * from marts.mart_vintage_curves order by vintage_quarter, product_name, months_on_book",
    "mart_utilization_risk": "select * from marts.mart_utilization_risk order by observation_month, product_name, fico_band, utilization_band",
    "mart_dq_rejections": "select * from marts.mart_dq_rejections order by source_table, dq_check",
    "mart_data_quality": "select * from marts.mart_data_quality order by status desc, model_name, test_name",
    "mart_dq_history": "select * from marts.mart_dq_history order by run_ts",
    "mart_pipeline_reconciliation": "select * from marts.mart_pipeline_reconciliation order by entity",
    "dim_product": "select * from marts.dim_product order by product_name",
    "dim_date_monthly": "select * from marts.dim_date where is_month_start and is_in_reporting_window order by date_day",
}


def human_size(n_bytes: int) -> str:
    size = float(n_bytes)
    for unit in ("B", "KB", "MB", "GB"):
        if size < 1024 or unit == "GB":
            return f"{size:,.0f} {unit}" if unit == "B" else f"{size:,.1f} {unit}"
        size /= 1024
    return f"{size:,.1f} GB"


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--db", default=os.environ.get("DUCKDB_PATH", "data/warehouse.duckdb"))
    parser.add_argument("--out", type=Path, default=Path("data/exports"))
    args = parser.parse_args()

    args.out.mkdir(parents=True, exist_ok=True)
    # Remove stale exports from earlier versions of this script (e.g. full fact tables).
    for old in args.out.glob("*.csv"):
        if old.stem not in EXPORTS:
            old.unlink()

    con = duckdb.connect(args.db, read_only=True)
    total = 0
    for name, query in EXPORTS.items():
        path = args.out / f"{name}.csv"
        con.execute(f"COPY ({query}) TO '{path.as_posix()}' (HEADER, DELIMITER ',')")
        rows = con.execute(f"select count(*) from ({query})").fetchone()[0]
        size = path.stat().st_size
        total += size
        print(f"  {path.name:<34} {rows:>8,} rows  {human_size(size):>9}")
    con.close()
    print(f"  {'total':<34} {'':>13}  {human_size(total):>9}")


if __name__ == "__main__":
    main()
