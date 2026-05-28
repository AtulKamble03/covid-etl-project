# etl/pipeline.py
#
# Phase 3 — Pipeline orchestrator
# Run this file to execute the full ETL in one command:
#
#   python etl/pipeline.py
#   python etl/pipeline.py --local      # use local CSV, skip download
#   python etl/pipeline.py --snowflake  # load to Snowflake instead of Postgres

import argparse
from loguru import logger
from extract import extract
from transform import transform
from load import load


def run_pipeline(use_local: bool = False, target: str = "postgres") -> None:
    logger.info("=" * 50)
    logger.info("COVID-19 ETL Pipeline starting")
    logger.info(f"  Source : {'local CSV' if use_local else 'OWID download'}")
    logger.info(f"  Target : {target}")
    logger.info("=" * 50)

    # Step 1 — Extract
    raw_df = extract(use_local=use_local)

    # Step 2 — Transform
    fact, dim_location, dim_date = transform(raw_df)

    # Step 3 — Load
    load(fact, dim_location, dim_date, target=target)

    logger.info("Pipeline finished successfully.")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Run the COVID-19 ETL pipeline")
    parser.add_argument("--local",      action="store_true", help="Use local CSV file")
    parser.add_argument("--snowflake",  action="store_true", help="Load to Snowflake")
    args = parser.parse_args()

    target = "snowflake" if args.snowflake else "postgres"
    run_pipeline(use_local=args.local, target=target)
