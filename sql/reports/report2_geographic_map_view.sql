-- ============================================================
-- REPORT 2 — Geographic Map View
-- Business Question: How many total cases, deaths, and
-- vaccinations are reported per country?
--
-- Sliceable by: Continent, Country
-- Key metrics: Total cases, deaths, vaccinations, CFR,
--              cases per million, vaccination coverage %
-- ============================================================

USE covid_dw;
GO

SELECT
    l.country,
    l.continent,
    l.code                                                         AS iso_code,
    FORMAT(l.population, 'N0')                                     AS population,

    -- Cases
    FORMAT(MAX(f.total_cases),  'N0')                              AS total_cases,
    FORMAT(MAX(f.total_cases) / NULLIF(l.population,0) * 1000000, 'N0') AS cases_per_million,

    -- Deaths
    FORMAT(MAX(f.total_deaths), 'N0')                              AS total_deaths,
    FORMAT(MAX(f.total_deaths) / NULLIF(MAX(f.total_cases),0) * 100, 'N2') + '%' AS case_fatality_rate,

    -- Vaccinations
    FORMAT(MAX(v.total_vaccinations), 'N0')                        AS total_vaccinations,
    FORMAT(MAX(v.people_vaccinated_per_hundred), 'N1')  + '%'      AS vaccinated_pct,
    FORMAT(MAX(v.people_fully_vaccinated_per_hundred), 'N1') + '%' AS fully_vaccinated_pct,

    -- Demographics
    l.gdp_per_capita,
    l.median_age,
    l.hospital_beds_per_thousand
FROM dbo.dim_location l
LEFT JOIN dbo.fact_covid_cases f ON f.location_id = l.location_id
LEFT JOIN dbo.fact_vaccination v ON v.location_id = l.location_id
WHERE l.continent <> '' AND l.continent IS NOT NULL
GROUP BY l.country, l.continent, l.code, l.population,
         l.gdp_per_capita, l.median_age, l.hospital_beds_per_thousand
ORDER BY MAX(f.total_cases) DESC;
