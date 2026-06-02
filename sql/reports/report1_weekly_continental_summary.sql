-- ============================================================
-- REPORT 1 — Weekly Continental Summary
-- Business Question: What is the week-over-week % change in
-- new COVID-19 cases per continent?
--
-- Sliceable by: Continent, Year, Week
-- Key metric: WoW % change in new cases and deaths
-- ============================================================

USE covid_dw;
GO

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
         ELSE 'N/A'
    END                              AS wow_cases_pct_change,
    CASE WHEN prev_week_deaths > 0
         THEN FORMAT(ROUND((weekly_new_deaths - prev_week_deaths) / NULLIF(prev_week_deaths,0) * 100, 1), 'N1') + '%'
         ELSE 'N/A'
    END                              AS wow_deaths_pct_change
FROM wow
-- Filter example: WHERE continent = 'Europe' AND year = 2022
ORDER BY continent, year, week_number;
