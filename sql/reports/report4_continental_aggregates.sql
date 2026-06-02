-- ============================================================
-- REPORT 4 — Continental Aggregates
-- Business Question: How many total COVID-19 cases have been
-- reported per continent?
--
-- Sliceable by: Continent
-- Key metrics: Total cases, total deaths, CFR, country count
-- ============================================================

USE covid_dw;
GO

SELECT
    l.continent,
    COUNT(DISTINCT l.country)                                        AS countries_reporting,
    FORMAT(SUM(f.new_cases),  'N0')                                  AS total_cases,
    FORMAT(SUM(f.new_deaths), 'N0')                                  AS total_deaths,
    FORMAT(
        SUM(f.new_deaths) / NULLIF(SUM(f.new_cases), 0) * 100, 'N3'
    ) + '%'                                                          AS case_fatality_rate,
    FORMAT(SUM(f.new_cases) / NULLIF(SUM(l.population), 0) * 1000000, 'N0') AS cases_per_million_avg
FROM dbo.fact_covid_cases f
JOIN dbo.dim_location l ON l.location_id = f.location_id
WHERE l.continent <> '' AND l.continent IS NOT NULL
GROUP BY l.continent
ORDER BY SUM(f.new_cases) DESC;
