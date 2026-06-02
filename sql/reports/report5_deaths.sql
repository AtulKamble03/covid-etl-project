-- ============================================================
-- REPORT 5 — Deaths
-- Business Question: How many deaths in the last 7/28 days?
-- Which countries have the highest case fatality rate?
--
-- Sliceable by: Country, Continent
-- Key metrics: New deaths (7d, 28d), cumulative deaths, CFR
-- ============================================================

USE covid_dw;
GO

WITH latest AS (
    SELECT f.location_id, MAX(d.date) AS latest_date
    FROM dbo.fact_covid_cases f
    JOIN dbo.dim_date d ON d.date_id = f.date_id
    GROUP BY f.location_id
)
SELECT
    l.country,
    l.continent,

    -- Cumulative
    FORMAT(MAX(f.total_deaths), 'N0')                                AS cumulative_deaths,
    FORMAT(MAX(f.total_cases),  'N0')                                AS cumulative_cases,
    FORMAT(MAX(f.total_deaths) / NULLIF(MAX(f.total_cases),0) * 100, 'N2') + '%' AS case_fatality_rate,

    -- Rolling windows (relative to each country's latest data date)
    FORMAT(SUM(CASE WHEN d.date >= DATEADD(DAY,-7,  lt.latest_date) THEN ISNULL(f.new_deaths,0) ELSE 0 END), 'N0') AS deaths_last_7d,
    FORMAT(SUM(CASE WHEN d.date >= DATEADD(DAY,-28, lt.latest_date) THEN ISNULL(f.new_deaths,0) ELSE 0 END), 'N0') AS deaths_last_28d,

    -- 7-day smoothed average (OWID pre-computed)
    FORMAT(MAX(f.new_deaths_smoothed), 'N1')                         AS deaths_7d_avg,
    FORMAT(MAX(f.new_deaths_per_million), 'N2')                      AS deaths_per_million

FROM dbo.fact_covid_cases f
JOIN dbo.dim_location l  ON l.location_id  = f.location_id
JOIN dbo.dim_date     d  ON d.date_id      = f.date_id
JOIN latest           lt ON lt.location_id = f.location_id
WHERE l.continent <> '' AND l.continent IS NOT NULL
GROUP BY l.country, l.continent, lt.latest_date
HAVING MAX(f.total_cases) > 10000   -- exclude micro-territories with very few cases
ORDER BY MAX(f.total_deaths) DESC;
