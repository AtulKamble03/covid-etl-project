-- sql/create_tables.sql
-- Phase 2 — Star schema DDL
-- Run this in pgAdmin or DBeaver to create the warehouse tables manually.
-- Note: pipeline.py also creates these automatically via df.to_sql()

-- ── Create database (run once as superuser) ──────────────────────────────────
-- CREATE DATABASE covid_dw;

-- ── Drop existing tables (safe re-run) ───────────────────────────────────────
DROP TABLE IF EXISTS fact_covid_daily;
DROP TABLE IF EXISTS dim_location;
DROP TABLE IF EXISTS dim_date;

-- ── Dimension: location ───────────────────────────────────────────────────────
CREATE TABLE dim_location (
    location_id   SERIAL PRIMARY KEY,
    iso_code      VARCHAR(10)  NOT NULL UNIQUE,
    continent     VARCHAR(50),
    location      VARCHAR(100) NOT NULL,
    population    BIGINT
);

-- ── Dimension: date ───────────────────────────────────────────────────────────
CREATE TABLE dim_date (
    date_id      SERIAL PRIMARY KEY,
    date         DATE         NOT NULL UNIQUE,
    year         SMALLINT     NOT NULL,
    month        SMALLINT     NOT NULL,
    month_name   VARCHAR(10)  NOT NULL,
    quarter      SMALLINT     NOT NULL,
    week_number  SMALLINT     NOT NULL
);

-- ── Fact: daily COVID metrics ─────────────────────────────────────────────────
CREATE TABLE fact_covid_daily (
    id                   SERIAL PRIMARY KEY,
    date_id              INT REFERENCES dim_date(date_id),
    location_id          INT REFERENCES dim_location(location_id),
    new_cases            FLOAT,
    new_deaths           FLOAT,
    new_vaccinations     FLOAT,
    total_cases          FLOAT,
    total_deaths         FLOAT,
    total_vaccinations   FLOAT,
    reproduction_rate    FLOAT
);

-- ── Indexes for common query patterns ────────────────────────────────────────
CREATE INDEX idx_fact_date     ON fact_covid_daily(date_id);
CREATE INDEX idx_fact_location ON fact_covid_daily(location_id);
