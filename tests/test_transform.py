# tests/test_transform.py
#
# Basic unit tests for the transform step.
# Run with:  python -m pytest tests/

import pandas as pd
import sys
import os
sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..', 'etl'))

from transform import transform


def _sample_df():
    """Minimal synthetic DataFrame that mirrors the OWID structure."""
    return pd.DataFrame({
        "iso_code":          ["IND", "USA", "GBR", "OWID_WORLD"],
        "continent":         ["Asia", "North America", "Europe", None],
        "location":          ["India", "United States", "United Kingdom", "World"],
        "date":              ["2021-01-01", "2021-01-01", "2021-01-01", "2021-01-01"],
        "new_cases":         [15000, 200000, 55000, None],
        "new_deaths":        [200, 3000, 1000, None],
        "new_vaccinations":  [None, 500000, 200000, None],
        "total_cases":       [10000000, 20000000, 3000000, None],
        "total_deaths":      [150000, 350000, 80000, None],
        "total_vaccinations":[None, 1000000, 400000, None],
        "population":        [1380000000, 331000000, 67000000, None],
        "reproduction_rate": [1.1, 0.9, 1.0, None],
    })


def test_owid_aggregates_removed():
    """Rows with iso_code starting OWID_ should be dropped."""
    fact, loc, dt = transform(_sample_df())
    assert "World" not in loc["location"].values


def test_new_vaccinations_null_filled():
    """NaN in new_vaccinations should be replaced with 0."""
    fact, loc, dt = transform(_sample_df())
    assert fact["new_vaccinations"].isna().sum() == 0


def test_dim_location_unique_iso():
    """dim_location must have one row per iso_code."""
    _, loc, _ = transform(_sample_df())
    assert loc["iso_code"].is_unique


def test_dim_date_columns():
    """dim_date must contain year, month, quarter, week_number."""
    _, _, dt = transform(_sample_df())
    for col in ["year", "month", "quarter", "week_number"]:
        assert col in dt.columns, f"Missing column: {col}"


def test_fact_has_fk_ids():
    """fact_covid_daily must have date_id and location_id columns."""
    fact, _, _ = transform(_sample_df())
    assert "date_id" in fact.columns
    assert "location_id" in fact.columns


def test_row_counts_match():
    """fact row count should equal number of valid country-date combinations."""
    df = _sample_df()
    fact, loc, dt = transform(df)
    # 3 real countries × 1 date = 3 fact rows
    assert len(fact) == 3
