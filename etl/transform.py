# etl/transform.py
#
# Phase 3 — Transform
# Cleans the raw DataFrame and splits it into:
#   - fact_covid_daily  (metrics)
#   - dim_location      (country / region context)
#   - dim_date          (date hierarchy)

import pandas as pd
from loguru import logger


# Columns we actually need from the raw ~60-column CSV
REQUIRED_COLUMNS = [
    "iso_code", "continent", "location", "date",
    "new_cases", "new_deaths", "new_vaccinations",
    "total_cases", "total_deaths", "total_vaccinations",
    "population", "reproduction_rate",
]

# Numeric columns where NaN means zero
FILL_ZERO_COLUMNS = [
    "new_cases", "new_deaths", "new_vaccinations",
    "total_cases", "total_deaths", "total_vaccinations",
]


def transform(df: pd.DataFrame) -> tuple[pd.DataFrame, pd.DataFrame, pd.DataFrame]:
    """
    Clean the raw OWID DataFrame and produce three warehouse-ready tables.

    Args:
        df: Raw DataFrame from extract.py

    Returns:
        Tuple of (fact_covid_daily, dim_location, dim_date)
    """
    logger.info("Starting transform...")

    # ── 1. Select and validate columns ──────────────────────────
    missing = [c for c in REQUIRED_COLUMNS if c not in df.columns]
    if missing:
        raise ValueError(f"Missing expected columns: {missing}")

    df = df[REQUIRED_COLUMNS].copy()

    # ── 2. Parse dates ───────────────────────────────────────────
    df["date"] = pd.to_datetime(df["date"])

    # ── 3. Drop rows with no country or date ────────────────────
    before = len(df)
    df = df.dropna(subset=["iso_code", "location", "date"])
    # Remove OWID aggregate rows (e.g. "World", "Asia") — they have
    # iso_codes starting with "OWID_"
    df = df[~df["iso_code"].str.startswith("OWID_")]
    logger.info(f"Dropped {before - len(df):,} invalid/aggregate rows")

    # ── 4. Fill numeric nulls ────────────────────────────────────
    df[FILL_ZERO_COLUMNS] = df[FILL_ZERO_COLUMNS].fillna(0)

    # ── 5. Build dim_location ────────────────────────────────────
    dim_location = (
        df[["iso_code", "continent", "location", "population"]]
        .drop_duplicates(subset=["iso_code"])
        .reset_index(drop=True)
    )
    dim_location.insert(0, "location_id", range(1, len(dim_location) + 1))
    logger.info(f"dim_location: {len(dim_location):,} rows")

    # ── 6. Build dim_date ────────────────────────────────────────
    dates = df[["date"]].drop_duplicates().sort_values("date").reset_index(drop=True)
    dates.insert(0, "date_id", range(1, len(dates) + 1))
    dates["year"]        = dates["date"].dt.year
    dates["month"]       = dates["date"].dt.month
    dates["month_name"]  = dates["date"].dt.strftime("%B")
    dates["quarter"]     = dates["date"].dt.quarter
    dates["week_number"] = dates["date"].dt.isocalendar().week.astype(int)
    dim_date = dates
    logger.info(f"dim_date: {len(dim_date):,} rows")

    # ── 7. Build fact_covid_daily ────────────────────────────────
    fact = df.merge(
        dim_location[["location_id", "iso_code"]], on="iso_code", how="left"
    ).merge(
        dim_date[["date_id", "date"]], on="date", how="left"
    )

    fact_covid_daily = fact[[
        "date_id", "location_id",
        "new_cases", "new_deaths", "new_vaccinations",
        "total_cases", "total_deaths", "total_vaccinations",
        "reproduction_rate",
    ]].reset_index(drop=True)

    logger.info(f"fact_covid_daily: {len(fact_covid_daily):,} rows")
    logger.info("Transform complete.")

    return fact_covid_daily, dim_location, dim_date


if __name__ == "__main__":
    from extract import extract
    raw = extract(use_local=True)
    fact, loc, dt = transform(raw)
    print(fact.head())
    print(loc.head())
    print(dt.head())
