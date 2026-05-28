# High Level Design (HLD)

## System Overview

Four layers — source, ETL, storage, analytics.

```
┌─────────────────────────────────────────────────────────────────┐
│  SOURCE                                                         │
│  owid_covid_compact.csv  │  hospital.csv  │  vaccinations_global.csv │
└───────────────────────────────┬─────────────────────────────────┘
                                │
                                ▼
┌─────────────────────────────────────────────────────────────────┐
│  ETL — SSIS Package (Visual Studio)                             │
│                                                                 │
│  Flow 1: compact CSV → dim_location                             │
│    Filter aggregate rows (continent IS NULL)                    │
│    Deduplicate → one row per country                            │
│    Type cast → load                                             │
│                                                                 │
│  Flow 2: Generated → dim_date                                   │
│    Generate all dates 2020-01-01 to today                       │
│    Derive year / month / quarter / week / day_of_week           │
│                                                                 │
│  Flow 3: compact CSV → fact_covid_cases                         │
│    DQ filter (null date, future date, null continent,           │
│               negative cases/deaths) → reject table             │
│    Type cast → Lookup location_id → Lookup date_id → load      │
│                                                                 │
│  Flow 4: vaccinations_global.csv → fact_vaccination             │
│    DQ filter (null date, future date) → reject table            │
│    Type cast → Lookup location_id (by name) → Lookup date_id   │
│    → load                                                       │
│                                                                 │
│  Flow 5: hospital.csv → fact_hospitalization                    │
│    DQ filter (null date, future date) → reject table            │
│    Type cast → Lookup location_id (by ISO-3 code)              │
│    → Lookup date_id → load                                      │
│                                                                 │
│  Flow 6: EXEC usp_verify_etl_load (post-load verification)     │
│    9 checks → PASS continues / FAIL raises error                │
└───────────────────────────────┬─────────────────────────────────┘
                                │
                                ▼
┌─────────────────────────────────────────────────────────────────┐
│  STORAGE — SQL Server Data Warehouse (Star Schema)              │
│  dim_location │ dim_date │ fact_covid_cases                     │
│  fact_vaccination │ fact_hospitalization                        │
│                                                                 │
│  Phase 5: Migrate to Snowflake (same schema, ODBC connector)    │
└───────────────────────────────┬─────────────────────────────────┘
                                │
                                ▼
┌─────────────────────────────────────────────────────────────────┐
│  ANALYTICS                                                      │
│  SSMS SQL queries │ Power BI / SSRS reports │ 8 business reports│
└─────────────────────────────────────────────────────────────────┘
```

## Layer Summary

| Layer | Tools | Purpose |
|---|---|---|
| Source | CSV files (OWID) | Raw COVID-19 data — cases, deaths, hospitalizations, vaccinations |
| ETL | SSIS (Visual Studio) | Extract, validate, transform, and load data |
| Storage | SQL Server → Snowflake | Star schema data warehouse |
| Analytics | SSMS, Power BI, SSRS | Answer 8 business reports |

## Key Design Principles

- **Separation of concerns:** Each layer is independent. Swapping SQL Server → Snowflake in Phase 5 does not require changing SSIS transform logic.
- **Dimensions load first:** Foreign key integrity — `dim_location` and `dim_date` must exist before fact rows are inserted.
- **Reject table:** Bad rows are never silently dropped — they go to `dq_rejected_rows` with reason codes.
- **Grain:** Lowest level is country × day. All weekly/monthly aggregates are computed at query time.
