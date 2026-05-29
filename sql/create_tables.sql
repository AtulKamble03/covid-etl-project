-- sql/create_tables.sql
-- Phase 2 — Star schema DDL for SQL Server
-- Run in SSMS connected to your local SQL Server instance.
-- Creates the database, all 5 warehouse tables, the DQ reject table, and indexes.

-- ── Create database (run once, then switch context) ──────────────────────────
-- CREATE DATABASE covid_dw;
-- GO
USE covid_dw;
GO

-- ── Drop tables in FK-safe order (facts first, then dims) ────────────────────
IF OBJECT_ID('dbo.fact_hospitalization', 'U') IS NOT NULL DROP TABLE dbo.fact_hospitalization;
IF OBJECT_ID('dbo.fact_vaccination',     'U') IS NOT NULL DROP TABLE dbo.fact_vaccination;
IF OBJECT_ID('dbo.fact_covid_cases',     'U') IS NOT NULL DROP TABLE dbo.fact_covid_cases;
IF OBJECT_ID('dbo.dq_rejected_rows',     'U') IS NOT NULL DROP TABLE dbo.dq_rejected_rows;
IF OBJECT_ID('dbo.dim_date',             'U') IS NOT NULL DROP TABLE dbo.dim_date;
IF OBJECT_ID('dbo.dim_location',         'U') IS NOT NULL DROP TABLE dbo.dim_location;
GO

-- ── Dimension: location ──────────────────────────────────────────────────────
-- Source: owid_covid_compact.csv | One row per country | Upsert by code (ISO-3)
CREATE TABLE dbo.dim_location (
    location_id                INT IDENTITY(1,1) PRIMARY KEY,
    country                    NVARCHAR(100) NOT NULL,
    code                       CHAR(3)       NOT NULL UNIQUE,  -- ISO-3 — natural key for upsert
    continent                  NVARCHAR(50)  NOT NULL,
    population                 BIGINT,
    population_density         FLOAT,
    median_age                 FLOAT,
    life_expectancy            FLOAT,
    gdp_per_capita             FLOAT,
    diabetes_prevalence        FLOAT,
    handwashing_facilities     FLOAT,
    hospital_beds_per_thousand FLOAT
);
GO

-- ── Dimension: date ──────────────────────────────────────────────────────────
-- Source: Generated (2020-01-01 to today) | Truncate + full reload every run
CREATE TABLE dbo.dim_date (
    date_id     INT IDENTITY(1,1) PRIMARY KEY,
    date        DATE         NOT NULL UNIQUE,
    year        SMALLINT     NOT NULL,
    month       TINYINT      NOT NULL,
    month_name  NVARCHAR(10) NOT NULL,
    quarter     CHAR(2)      NOT NULL,   -- Q1, Q2, Q3, Q4
    week_number TINYINT      NOT NULL,   -- ISO week number
    day_of_week NVARCHAR(10) NOT NULL,   -- Monday … Sunday
    is_weekend  BIT          NOT NULL    -- 1 = Saturday or Sunday
);
GO

-- ── Partition function and scheme ────────────────────────────────────────────
-- Partitions all three fact tables by year (record_year SMALLINT).
-- RANGE RIGHT: each boundary value is the START of a new partition.
-- 7 partitions covering 2020-2026+.
CREATE PARTITION FUNCTION pf_covid_year (SMALLINT)
AS RANGE RIGHT FOR VALUES (2021, 2022, 2023, 2024, 2025, 2026);
-- P1: record_year <  2021  →  2020 data
-- P2: record_year =  2021
-- P3: record_year =  2022
-- P4: record_year =  2023
-- P5: record_year =  2024
-- P6: record_year =  2025
-- P7: record_year >= 2026  →  2026 and any future data
GO

-- All partitions on PRIMARY filegroup for this learning project.
-- In production, each partition would map to a separate filegroup on its own disk.
CREATE PARTITION SCHEME ps_covid_year
AS PARTITION pf_covid_year ALL TO ([PRIMARY]);
GO

-- ── Fact: COVID cases and deaths ─────────────────────────────────────────────
-- Source: owid_covid_compact.csv | Grain: country × day | Truncate + full reload
-- record_year: partition key — derived from date column by SSIS Derived Column component.
-- Smoothed and per-million columns are pre-computed by OWID — passed through as-is.
-- Nullable columns: reproduction_rate, stringency_index, new_tests_smoothed,
--                   positive_rate, tests_per_case (sparse in source data).
CREATE TABLE dbo.fact_covid_cases (
    case_id                BIGINT   IDENTITY(1,1) NOT NULL,
    record_year            SMALLINT              NOT NULL,  -- partition key
    location_id            INT                   NOT NULL REFERENCES dbo.dim_location(location_id),
    date_id                INT                   NOT NULL REFERENCES dbo.dim_date(date_id),
    new_cases              FLOAT,
    total_cases            FLOAT,
    new_cases_smoothed     FLOAT,
    new_cases_per_million  FLOAT,
    new_deaths             FLOAT,
    total_deaths           FLOAT,
    new_deaths_smoothed    FLOAT,
    new_deaths_per_million FLOAT,
    reproduction_rate      FLOAT,
    stringency_index       FLOAT,
    new_tests_smoothed     FLOAT,  -- 82% null across dataset
    positive_rate          FLOAT,  -- 82% null across dataset
    tests_per_case         FLOAT,
    -- PK must include partition key (SQL Server requirement for aligned indexes)
    CONSTRAINT pk_fact_covid_cases       PRIMARY KEY NONCLUSTERED (case_id, record_year),
    CONSTRAINT uq_covid_cases_loc_date   UNIQUE NONCLUSTERED (location_id, date_id, record_year)
) ON ps_covid_year (record_year);
GO

-- Clustered index on partition scheme — enables partition elimination for year-range queries
CREATE CLUSTERED INDEX ci_fact_covid_cases
ON dbo.fact_covid_cases (record_year, location_id, date_id)
ON ps_covid_year (record_year);
GO

-- ── Fact: vaccinations ───────────────────────────────────────────────────────
-- Source: vaccinations_global.csv | Grain: country × day | Truncate + full reload
-- Location joined by country name (no ISO code in this file).
-- Rolling averages (6m, 9m, 12m) are pre-computed by OWID — passed through as-is.
CREATE TABLE dbo.fact_vaccination (
    vaccination_id                      BIGINT   IDENTITY(1,1) NOT NULL,
    record_year                         SMALLINT              NOT NULL,  -- partition key
    location_id                         INT                   NOT NULL REFERENCES dbo.dim_location(location_id),
    date_id                             INT                   NOT NULL REFERENCES dbo.dim_date(date_id),
    total_vaccinations                  FLOAT,
    people_vaccinated                   FLOAT,
    people_fully_vaccinated             FLOAT,
    total_boosters                      FLOAT,
    daily_vaccinations_smoothed         FLOAT,
    people_vaccinated_per_hundred       FLOAT,
    people_fully_vaccinated_per_hundred FLOAT,
    total_boosters_per_hundred          FLOAT,
    people_unvaccinated                 FLOAT,
    rolling_vaccinations_6m             FLOAT,
    rolling_vaccinations_9m             FLOAT,
    rolling_vaccinations_12m            FLOAT,
    CONSTRAINT pk_fact_vaccination       PRIMARY KEY NONCLUSTERED (vaccination_id, record_year),
    CONSTRAINT uq_vaccination_loc_date   UNIQUE NONCLUSTERED (location_id, date_id, record_year)
) ON ps_covid_year (record_year);
GO

CREATE CLUSTERED INDEX ci_fact_vaccination
ON dbo.fact_vaccination (record_year, location_id, date_id)
ON ps_covid_year (record_year);
GO

-- ── Fact: hospitalization and ICU ────────────────────────────────────────────
-- Source: hospital.csv | Grain: country × day | Truncate + full reload
-- Location joined by country_code (ISO-3) — more reliable than name matching.
-- ~93% null across dataset — coverage limited to countries that report to OWID.
CREATE TABLE dbo.fact_hospitalization (
    hosp_id                       BIGINT   IDENTITY(1,1) NOT NULL,
    record_year                   SMALLINT              NOT NULL,  -- partition key
    location_id                   INT                   NOT NULL REFERENCES dbo.dim_location(location_id),
    date_id                       INT                   NOT NULL REFERENCES dbo.dim_date(date_id),
    daily_occupancy_hosp          FLOAT,
    daily_occupancy_hosp_per_1m   FLOAT,
    daily_occupancy_icu           FLOAT,
    daily_occupancy_icu_per_1m    FLOAT,
    weekly_admissions_hosp        FLOAT,
    weekly_admissions_hosp_per_1m FLOAT,
    weekly_admissions_icu         FLOAT,
    weekly_admissions_icu_per_1m  FLOAT,
    CONSTRAINT pk_fact_hospitalization     PRIMARY KEY NONCLUSTERED (hosp_id, record_year),
    CONSTRAINT uq_hospitalization_loc_date UNIQUE NONCLUSTERED (location_id, date_id, record_year)
) ON ps_covid_year (record_year);
GO

CREATE CLUSTERED INDEX ci_fact_hospitalization
ON dbo.fact_hospitalization (record_year, location_id, date_id)
ON ps_covid_year (record_year);
GO

-- ── DQ reject table ──────────────────────────────────────────────────────────
-- Rows that fail any DQ check or lookup are written here by SSIS error outputs.
-- rule_id values:
--   DQ-CAST      : Data Conversion cast failure (e.g. "N/A" in numeric column, malformed date)
--   DQ-01        : date IS NULL
--   DQ-02        : date > GETDATE() (future date)
--   DQ-03        : continent IS NULL (aggregate/non-country row)
--   DQ-04        : new_cases < 0
--   DQ-05        : new_deaths < 0
--   DQ-09        : positive_rate > 1 (impossible value)
--   DQ-10        : stringency_index > 100 (impossible value)
--   LOOKUP-LOC   : country/country_code not found in dim_location
--   LOOKUP-DATE  : date not found in dim_date
CREATE TABLE dbo.dq_rejected_rows (
    reject_id      INT IDENTITY(1,1) PRIMARY KEY,
    source_file    NVARCHAR(100) NOT NULL,
    rule_id        VARCHAR(15)   NOT NULL,
    reject_reason  NVARCHAR(500),
    raw_country    NVARCHAR(100),
    raw_date       NVARCHAR(50),
    raw_new_cases  NVARCHAR(50),
    raw_new_deaths NVARCHAR(50),
    load_timestamp DATETIME2     NOT NULL DEFAULT GETDATE()
);
GO

-- ── ETL run log ──────────────────────────────────────────────────────────────
-- One row per Data Flow per package execution.
-- Populated by Execute SQL Tasks in the SSIS Control Flow after each Data Flow.
-- rows_extracted = rows_loaded + rows_rejected + rows_discarded (should always be 0).
CREATE TABLE dbo.etl_run_log (
    run_id          INT IDENTITY(1,1) PRIMARY KEY,
    run_timestamp   DATETIME2     NOT NULL DEFAULT GETDATE(),
    flow_name       NVARCHAR(50)  NOT NULL,   -- e.g. 'fact_covid_cases'
    source_file     NVARCHAR(100) NOT NULL,   -- e.g. 'owid_covid_compact.csv'
    rows_extracted  INT           NOT NULL,   -- total rows read by Flat File Source
    rows_loaded     INT           NOT NULL,   -- rows written to target fact/dim table
    rows_rejected   INT           NOT NULL,   -- rows written to dq_rejected_rows
    rows_discarded  INT           NOT NULL DEFAULT 0,  -- rows lost silently (must be 0)
    package_status  NVARCHAR(10)  NOT NULL DEFAULT 'COMPLETE'  -- COMPLETE or FAILED
);
GO

-- ── Additional non-clustered indexes ─────────────────────────────────────────
-- The clustered index (record_year, location_id, date_id) already covers most
-- query patterns. These non-clustered indexes support the remaining access patterns.
CREATE INDEX idx_covid_cases_date       ON dbo.fact_covid_cases(date_id)     ON ps_covid_year (record_year);
CREATE INDEX idx_vaccination_date       ON dbo.fact_vaccination(date_id)     ON ps_covid_year (record_year);
CREATE INDEX idx_hospitalization_date   ON dbo.fact_hospitalization(date_id) ON ps_covid_year (record_year);
GO

-- ── Useful queries for learning about partitions ──────────────────────────────
-- Check how many rows are in each partition after loading:
--
-- SELECT
--     p.partition_number,
--     prv.value      AS year_boundary,
--     p.rows         AS row_count
-- FROM sys.partitions p
-- JOIN sys.tables t ON t.object_id = p.object_id
-- LEFT JOIN sys.partition_range_values prv
--     ON prv.function_id = (SELECT function_id FROM sys.partition_schemes
--                            WHERE name = 'ps_covid_year')
--    AND prv.boundary_id = p.partition_number - 1
-- WHERE t.name = 'fact_covid_cases'
--   AND p.index_id IN (0, 1)  -- 0 = heap, 1 = clustered
-- ORDER BY p.partition_number;
