-- ============================================================
-- COVID-19 Data Warehouse — Analytical Queries
-- Run in SSMS against: covid_dw
-- All aggregations computed at query time (no ETL aggregation)
-- ============================================================

USE covid_dw;
GO

-- ============================================================
-- REPORT 1 — Weekly Continental Summary
-- Week-over-week % change in new cases per continent
-- ============================================================

WITH weekly_cases AS (
    SELECT
        l.continent,
        d.year,
        d.week_number,
        MIN(d.date)          AS week_start,
        SUM(f.new_cases)     AS weekly_new_cases,
        SUM(f.new_deaths)    AS weekly_new_deaths
    FROM dbo.fact_covid_cases f
    JOIN dbo.dim_location l ON l.location_id = f.location_id
    JOIN dbo.dim_date     d ON d.date_id     = f.date_id
    WHERE l.continent <> '' AND l.continent IS NOT NULL
    GROUP BY l.continent, d.year, d.week_number
),
wow AS (
    SELECT *,
        LAG(weekly_new_cases)  OVER (PARTITION BY continent ORDER BY year, week_number) AS prev_week_cases,
        LAG(weekly_new_deaths) OVER (PARTITION BY continent ORDER BY year, week_number) AS prev_week_deaths
    FROM weekly_cases
)
SELECT
    continent,
    year,
    week_number,
    week_start,
    FORMAT(weekly_new_cases,  'N0')  AS weekly_new_cases,
    FORMAT(weekly_new_deaths, 'N0')  AS weekly_new_deaths,
    CASE WHEN prev_week_cases > 0
         THEN FORMAT(ROUND((weekly_new_cases - prev_week_cases) / NULLIF(prev_week_cases,0) * 100, 1), 'N1') + '%'
         ELSE 'N/A' END              AS wow_cases_pct_change
FROM wow
ORDER BY continent, year, week_number;
GO


-- ============================================================
-- REPORT 2 — Geographic View
-- Total cases, deaths, vaccinations per country
-- ============================================================

SELECT
    l.country,
    l.continent,
    l.code,
    FORMAT(l.population, 'N0')                                    AS population,
    FORMAT(MAX(f.total_cases),  'N0')                             AS total_cases,
    FORMAT(MAX(f.total_deaths), 'N0')                             AS total_deaths,
    FORMAT(MAX(f.total_cases) / NULLIF(l.population,0) * 1000000,'N0') AS cases_per_million,
    FORMAT(MAX(f.total_deaths) / NULLIF(MAX(f.total_cases),0) * 100, 'N2') + '%' AS case_fatality_rate,
    FORMAT(MAX(v.total_vaccinations), 'N0')                       AS total_vaccinations,
    FORMAT(MAX(v.people_fully_vaccinated_per_hundred), 'N1') + '%' AS fully_vaccinated_pct,
    l.gdp_per_capita,
    l.median_age
FROM dbo.dim_location l
LEFT JOIN dbo.fact_covid_cases f ON f.location_id = l.location_id
LEFT JOIN dbo.fact_vaccination v ON v.location_id = l.location_id
WHERE l.continent <> '' AND l.continent IS NOT NULL
GROUP BY l.country, l.continent, l.code, l.population, l.gdp_per_capita, l.median_age
ORDER BY MAX(f.total_cases) DESC;
GO


-- ============================================================
-- REPORT 3 — Cases Over Time
-- 7-day rolling avg, 28-day total, cumulative per country
-- ============================================================

SELECT
    l.country,
    l.continent,
    d.date,
    f.new_cases,
    f.new_cases_smoothed                                    AS new_cases_7d_avg_owid,
    SUM(f.new_cases) OVER (
        PARTITION BY f.location_id
        ORDER BY d.date
        ROWS BETWEEN 27 PRECEDING AND CURRENT ROW
    )                                                       AS new_cases_28d_rolling,
    f.total_cases                                           AS cumulative_cases,
    f.new_cases_per_million
FROM dbo.fact_covid_cases f
JOIN dbo.dim_location l ON l.location_id = f.location_id
JOIN dbo.dim_date     d ON d.date_id     = f.date_id
WHERE l.continent <> '' AND l.continent IS NOT NULL
  AND f.new_cases IS NOT NULL
ORDER BY l.country, d.date;
GO


-- ============================================================
-- REPORT 4 — Continental Aggregates
-- Total cases per continent (all time)
-- ============================================================

SELECT
    l.continent,
    FORMAT(SUM(f.new_cases),  'N0')    AS total_cases,
    FORMAT(SUM(f.new_deaths), 'N0')    AS total_deaths,
    FORMAT(SUM(f.new_deaths) / NULLIF(SUM(f.new_cases),0) * 100, 'N3') + '%' AS overall_cfr,
    COUNT(DISTINCT l.country)          AS countries_reporting
FROM dbo.fact_covid_cases f
JOIN dbo.dim_location l ON l.location_id = f.location_id
WHERE l.continent <> '' AND l.continent IS NOT NULL
GROUP BY l.continent
ORDER BY SUM(f.new_cases) DESC;
GO


-- ============================================================
-- REPORT 5 — Deaths
-- 7d, 28d, cumulative deaths + CFR by country
-- ============================================================

WITH latest AS (
    SELECT f.location_id, MAX(d.date) AS latest_date
    FROM dbo.fact_covid_cases f
    JOIN dbo.dim_date d ON d.date_id = f.date_id
    GROUP BY f.location_id
)
SELECT
    l.country,
    l.continent,
    FORMAT(MAX(f.total_deaths), 'N0')    AS cumulative_deaths,
    FORMAT(MAX(f.total_cases),  'N0')    AS cumulative_cases,
    FORMAT(MAX(f.total_deaths) / NULLIF(MAX(f.total_cases),0) * 100, 'N2') + '%' AS case_fatality_rate,
    FORMAT(SUM(CASE WHEN d.date >= DATEADD(DAY, -7,  lt.latest_date) THEN ISNULL(f.new_deaths,0) ELSE 0 END), 'N0') AS deaths_last_7d,
    FORMAT(SUM(CASE WHEN d.date >= DATEADD(DAY, -28, lt.latest_date) THEN ISNULL(f.new_deaths,0) ELSE 0 END), 'N0') AS deaths_last_28d
FROM dbo.fact_covid_cases f
JOIN dbo.dim_location l  ON l.location_id  = f.location_id
JOIN dbo.dim_date     d  ON d.date_id      = f.date_id
JOIN latest           lt ON lt.location_id = f.location_id
WHERE l.continent <> '' AND l.continent IS NOT NULL
GROUP BY l.country, l.continent, lt.latest_date
HAVING MAX(f.total_cases) > 10000
ORDER BY MAX(f.total_deaths) DESC;
GO


-- ============================================================
-- REPORT 6 — Vaccination Coverage
-- Coverage %, supply gaps, rolling trends per country
-- ============================================================

SELECT
    l.country,
    l.continent,
    FORMAT(l.population, 'N0')                                        AS population,
    FORMAT(MAX(v.people_vaccinated),              'N0')               AS people_vaccinated,
    FORMAT(MAX(v.people_fully_vaccinated),        'N0')               AS fully_vaccinated,
    FORMAT(MAX(v.total_boosters),                 'N0')               AS total_boosters,
    FORMAT(MAX(v.people_vaccinated_per_hundred),  'N1') + '%'         AS vaccinated_pct,
    FORMAT(MAX(v.people_fully_vaccinated_per_hundred), 'N1') + '%'    AS fully_vaccinated_pct,
    FORMAT(MAX(v.people_unvaccinated),            'N0')               AS unvaccinated,
    FORMAT(MAX(v.rolling_vaccinations_6m),        'N0')               AS rolling_6m,
    FORMAT(MAX(v.rolling_vaccinations_12m),       'N0')               AS rolling_12m,
    CASE
        WHEN MAX(v.people_fully_vaccinated_per_hundred) < 40 THEN 'PRIORITY — Low coverage'
        WHEN MAX(v.people_fully_vaccinated_per_hundred) < 70 THEN 'MODERATE — Needs attention'
        ELSE 'HIGH — Good coverage'
    END                                                                AS supply_priority
FROM dbo.fact_vaccination v
JOIN dbo.dim_location l ON l.location_id = v.location_id
WHERE l.continent <> '' AND l.continent IS NOT NULL
GROUP BY l.country, l.continent, l.population
ORDER BY MAX(v.people_fully_vaccinated_per_hundred) ASC;
GO


-- ============================================================
-- REPORT 7 — Hospitalization and ICU
-- Latest occupancy and weekly admissions per country
-- ============================================================

WITH latest_hosp AS (
    SELECT h.location_id, MAX(d.date) AS latest_date
    FROM dbo.fact_hospitalization h
    JOIN dbo.dim_date d ON d.date_id = h.date_id
    GROUP BY h.location_id
)
SELECT
    l.country,
    l.continent,
    FORMAT(l.population, 'N0')                           AS population,
    FORMAT(MAX(h.daily_occupancy_hosp),     'N0')        AS current_hosp_occupancy,
    FORMAT(MAX(h.daily_occupancy_icu),      'N0')        AS current_icu_occupancy,
    FORMAT(MAX(h.daily_occupancy_hosp_per_1m), 'N2')    AS hosp_per_million,
    FORMAT(MAX(h.daily_occupancy_icu_per_1m),  'N2')    AS icu_per_million,
    FORMAT(MAX(h.weekly_admissions_hosp),   'N0')        AS weekly_hosp_admissions,
    FORMAT(MAX(h.weekly_admissions_icu),    'N0')        AS weekly_icu_admissions,
    lh.latest_date                                       AS data_as_of
FROM dbo.fact_hospitalization h
JOIN dbo.dim_location l  ON l.location_id  = h.location_id
JOIN dbo.dim_date     d  ON d.date_id      = h.date_id
JOIN latest_hosp      lh ON lh.location_id = h.location_id
WHERE l.continent <> '' AND l.continent IS NOT NULL
  AND d.date = lh.latest_date
GROUP BY l.country, l.continent, l.population, lh.latest_date
ORDER BY MAX(h.daily_occupancy_icu_per_1m) DESC;
GO


-- ============================================================
-- REPORT 8 — Testing
-- Total tests, positivity rate, 7d smoothed
-- Note: 82-87% null — only countries that reported to OWID
-- ============================================================

SELECT
    l.country,
    l.continent,
    FORMAT(SUM(f.new_tests_smoothed),   'N0')        AS total_tests_smoothed,
    FORMAT(AVG(f.positive_rate) * 100,  'N2') + '%'  AS avg_positivity_rate,
    FORMAT(MAX(f.positive_rate) * 100,  'N2') + '%'  AS peak_positivity_rate,
    FORMAT(AVG(f.tests_per_case),       'N1')        AS avg_tests_per_case,
    COUNT(CASE WHEN f.new_tests_smoothed IS NOT NULL THEN 1 END) AS days_reported,
    CASE
        WHEN AVG(f.positive_rate) > 0.10 THEN 'HIGH RISK — >10% positivity (possible under-reporting)'
        WHEN AVG(f.positive_rate) > 0.05 THEN 'ELEVATED — 5-10% positivity'
        ELSE 'ACCEPTABLE — <5% positivity'
    END                                               AS risk_signal
FROM dbo.fact_covid_cases f
JOIN dbo.dim_location l ON l.location_id = f.location_id
WHERE l.continent <> '' AND l.continent IS NOT NULL
  AND f.new_tests_smoothed IS NOT NULL
GROUP BY l.country, l.continent
HAVING COUNT(CASE WHEN f.new_tests_smoothed IS NOT NULL THEN 1 END) > 30
ORDER BY AVG(f.positive_rate) DESC;
GO
