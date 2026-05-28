-- sql/analytical_queries.sql
-- Phase 4 — Sample analytical queries
-- Run these in pgAdmin, DBeaver, or directly in Python via SQLAlchemy.

-- ── 1. Top 10 countries by total deaths ──────────────────────────────────────
SELECT
    l.location,
    l.continent,
    MAX(f.total_deaths)                              AS total_deaths,
    MAX(f.total_deaths) / NULLIF(l.population, 0) * 100000 AS deaths_per_100k
FROM fact_covid_daily f
JOIN dim_location l ON f.location_id = l.location_id
GROUP BY l.location, l.continent, l.population
ORDER BY total_deaths DESC
LIMIT 10;

-- ── 2. Monthly new cases globally ────────────────────────────────────────────
SELECT
    d.year,
    d.month_name,
    SUM(f.new_cases)  AS total_new_cases,
    SUM(f.new_deaths) AS total_new_deaths
FROM fact_covid_daily f
JOIN dim_date d ON f.date_id = d.date_id
GROUP BY d.year, d.month, d.month_name
ORDER BY d.year, d.month;

-- ── 3. Vaccination rollout by continent ──────────────────────────────────────
SELECT
    l.continent,
    d.year,
    d.quarter,
    SUM(f.new_vaccinations) AS vaccinations_given
FROM fact_covid_daily f
JOIN dim_location l ON f.location_id = l.location_id
JOIN dim_date     d ON f.date_id     = d.date_id
WHERE l.continent IS NOT NULL
GROUP BY l.continent, d.year, d.quarter
ORDER BY l.continent, d.year, d.quarter;

-- ── 4. 7-day rolling average of new cases — global ───────────────────────────
SELECT
    d.date,
    SUM(f.new_cases) AS daily_cases,
    AVG(SUM(f.new_cases)) OVER (
        ORDER BY d.date
        ROWS BETWEEN 6 PRECEDING AND CURRENT ROW
    ) AS rolling_7day_avg
FROM fact_covid_daily f
JOIN dim_date d ON f.date_id = d.date_id
GROUP BY d.date
ORDER BY d.date;

-- ── 5. Case fatality rate by country (where total_cases > 10,000) ────────────
SELECT
    l.location,
    l.continent,
    MAX(f.total_cases)  AS total_cases,
    MAX(f.total_deaths) AS total_deaths,
    ROUND(
        MAX(f.total_deaths) / NULLIF(MAX(f.total_cases), 0) * 100, 2
    ) AS case_fatality_rate_pct
FROM fact_covid_daily f
JOIN dim_location l ON f.location_id = l.location_id
GROUP BY l.location, l.continent
HAVING MAX(f.total_cases) > 10000
ORDER BY case_fatality_rate_pct DESC
LIMIT 20;
