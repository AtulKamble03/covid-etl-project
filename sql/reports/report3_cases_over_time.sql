-- ============================================================
-- REPORT 3 — Cases Over Time
-- Business Question: How many new cases were reported in the
-- last 7 days / 28 days per country? What is the trend?
--
-- Sliceable by: Country, Continent, Date range
-- Key metrics: Daily new cases, 7-day avg (OWID pre-computed),
--              28-day rolling total, cumulative cases
-- ============================================================

USE covid_dw;
GO

SELECT
    l.country,
    l.continent,
    d.date,
    d.year,
    d.quarter,
    d.week_number,

    -- Daily
    f.new_cases,
    f.new_cases_per_million,

    -- 7-day average (pre-computed by OWID)
    f.new_cases_smoothed                            AS new_cases_7d_avg,

    -- 28-day rolling total (computed at query time)
    SUM(f.new_cases) OVER (
        PARTITION BY f.location_id
        ORDER BY d.date
        ROWS BETWEEN 27 PRECEDING AND CURRENT ROW
    )                                               AS new_cases_28d_rolling,

    -- Cumulative
    f.total_cases                                   AS cumulative_cases

FROM dbo.fact_covid_cases f
JOIN dbo.dim_location l ON l.location_id = f.location_id
JOIN dbo.dim_date     d ON d.date_id     = f.date_id
WHERE l.continent <> '' AND l.continent IS NOT NULL
  AND f.new_cases IS NOT NULL
-- Filter example: WHERE l.country = 'India' AND d.year = 2022
ORDER BY l.country, d.date;
