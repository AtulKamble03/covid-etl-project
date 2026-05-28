# etl/load.py
#
# Phase 3 — Load
# Writes the three warehouse tables to PostgreSQL (local) or Snowflake.
# Switch target by passing target="postgres" or target="snowflake".

import pandas as pd
from sqlalchemy import create_engine, text
from loguru import logger

# Load order matters — dimensions before facts (foreign key safety)
LOAD_ORDER = ["dim_location", "dim_date", "fact_covid_daily"]


def _get_postgres_engine():
    """Build a SQLAlchemy engine for local PostgreSQL."""
    try:
        from config.db_config import PG_CONNECTION_STRING
    except ImportError:
        raise RuntimeError(
            "config/db_config.py not found. "
            "Copy config/db_config_example.py → config/db_config.py "
            "and fill in your credentials."
        )
    return create_engine(PG_CONNECTION_STRING)


def _get_snowflake_engine():
    """Build a SQLAlchemy engine for Snowflake (Phase 5)."""
    try:
        from config.db_config import SNOWFLAKE_CONFIG
    except ImportError:
        raise RuntimeError("config/db_config.py not found.")

    from snowflake.sqlalchemy import URL
    url = URL(
        account   = SNOWFLAKE_CONFIG["account"],
        user      = SNOWFLAKE_CONFIG["user"],
        password  = SNOWFLAKE_CONFIG["password"],
        database  = SNOWFLAKE_CONFIG["database"],
        schema    = SNOWFLAKE_CONFIG["schema"],
        warehouse = SNOWFLAKE_CONFIG["warehouse"],
    )
    return create_engine(url)


def load(
    fact: pd.DataFrame,
    dim_location: pd.DataFrame,
    dim_date: pd.DataFrame,
    target: str = "postgres",
    if_exists: str = "replace",
) -> None:
    """
    Load the three warehouse tables into the chosen target.

    Args:
        fact:         fact_covid_daily DataFrame
        dim_location: dim_location DataFrame
        dim_date:     dim_date DataFrame
        target:       "postgres" (default) or "snowflake"
        if_exists:    "replace" to drop-and-recreate, "append" to add rows
    """
    tables = {
        "dim_location":    dim_location,
        "dim_date":        dim_date,
        "fact_covid_daily": fact,
    }

    logger.info(f"Loading to {target}...")

    if target == "postgres":
        engine = _get_postgres_engine()
    elif target == "snowflake":
        engine = _get_snowflake_engine()
    else:
        raise ValueError(f"Unknown target '{target}'. Use 'postgres' or 'snowflake'.")

    with engine.connect() as conn:
        for table_name in LOAD_ORDER:
            df = tables[table_name]
            df.to_sql(
                name      = table_name,
                con       = conn,
                if_exists = if_exists,
                index     = False,
                chunksize = 10_000,
            )
            logger.info(f"  Loaded {len(df):,} rows → {table_name}")

    logger.info("Load complete.")


if __name__ == "__main__":
    from extract import extract
    from transform import transform
    raw = extract(use_local=True)
    fact, loc, dt = transform(raw)
    load(fact, loc, dt, target="postgres")
