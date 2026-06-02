-- ============================================================
-- REPORT 6 — Vaccination
-- Business Question: What is vaccination coverage % per country?
-- Which countries need supply prioritization?
--
-- Sliceable by: Country, Continent, Supply Priority
-- Key metrics: Vaccinated %, fully vaccinated %, boosters,
--              unvaccinated count, rolling trends (6m/9m/12m)
-- ============================================================

USE covid_dw;
GO

SELECT
    l.country,
    l.continent,
    FORMAT(l.population, 'N0')                                         AS population,

    -- Coverage counts
    FORMAT(MAX(v.people_vaccinated),        'N0')                      AS people_vaccinated,
    FORMAT(MAX(v.people_fully_vaccinated),  'N0')                      AS fully_vaccinated,
    FORMAT(MAX(v.total_boosters),           'N0')                      AS total_boosters,
    FORMAT(MAX(v.people_unvaccinated),      'N0')                      AS unvaccinated,

    -- Coverage percentages
    FORMAT(MAX(v.people_vaccinated_per_hundred),          'N1') + '%'  AS vaccinated_pct,
    FORMAT(MAX(v.people_fully_vaccinated_per_hundred),    'N1') + '%'  AS fully_vaccinated_pct,
    FORMAT(MAX(v.total_boosters_per_hundred),             'N1') + '%'  AS booster_pct,

    -- Rolling vaccination trends (pre-computed by OWID)
    FORMAT(MAX(v.rolling_vaccinations_6m),  'N0')                      AS rolling_6m,
    FORMAT(MAX(v.rolling_vaccinations_9m),  'N0')                      AS rolling_9m,
    FORMAT(MAX(v.rolling_vaccinations_12m), 'N0')                      AS rolling_12m,

    -- Supply priority classification
    CASE
        WHEN MAX(v.people_fully_vaccinated_per_hundred) IS NULL    THEN 'NO DATA'
        WHEN MAX(v.people_fully_vaccinated_per_hundred) < 40       THEN 'PRIORITY — Low coverage (<40%)'
        WHEN MAX(v.people_fully_vaccinated_per_hundred) < 70       THEN 'MODERATE — Needs attention (40-70%)'
        ELSE                                                             'HIGH — Good coverage (>70%)'
    END                                                                AS supply_priority

FROM dbo.fact_vaccination v
JOIN dbo.dim_location l ON l.location_id = v.location_id
WHERE l.continent <> '' AND l.continent IS NOT NULL
GROUP BY l.country, l.continent, l.population
ORDER BY MAX(v.people_fully_vaccinated_per_hundred) ASC;
