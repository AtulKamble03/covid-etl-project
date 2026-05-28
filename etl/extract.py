# etl/extract.py
#
# Phase 3 — Extract
# Downloads the Our World in Data COVID-19 CSV and returns a raw DataFrame.
#
# Data source : https://catalog.ourworldindata.org/garden/covid/latest/compact/compact.csv
# Licence     : Creative Commons BY 4.0

import pandas as pd
import requests
from loguru import logger

DATA_URL = "https://catalog.ourworldindata.org/garden/covid/latest/compact/compact.csv"
LOCAL_PATH = "data/owid_covid_compact.csv"


def extract(use_local: bool = False) -> pd.DataFrame:
    """
    Download (or load from disk) the OWID COVID-19 CSV.

    Args:
        use_local: If True, read from data/ folder instead of downloading.
                   Useful when offline or to speed up repeated runs.

    Returns:
        Raw pandas DataFrame with all original columns intact.
    """
    if use_local:
        logger.info(f"Loading local file: {LOCAL_PATH}")
        df = pd.read_csv(LOCAL_PATH)
    else:
        logger.info(f"Downloading dataset from {DATA_URL}")
        response = requests.get(DATA_URL, timeout=60)
        response.raise_for_status()

        # Save locally for future offline use
        with open(LOCAL_PATH, "wb") as f:
            f.write(response.content)
        logger.info(f"Saved to {LOCAL_PATH}")

        df = pd.read_csv(LOCAL_PATH)

    logger.info(f"Extracted {len(df):,} rows x {len(df.columns)} columns")
    return df


if __name__ == "__main__":
    df = extract()
    print(df.head())
    print(df.dtypes)
