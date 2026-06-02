-- ============================================================
-- REPORT 7 — Hospitalization and ICU
-- Business Question: How many patients are currently in hospital
-- / ICU? Which countries have highest ICU occupancy per million?
--
-- Sliceable by: Country, Continent
-- Key metrics: Current occupancy, weekly admissions, per million
-- Note: ~93% null — only countries reporting to OWID are shown
-- ============================================================

USE covid_dw;
GO

-- Latest available date per country (hospitalization data not always daily)
WITH latest_hosp AS (
    SELECT h.location_id, MAX(d.date) AS latest_date
    FROM dbo.fact_hospitalization h
    JOIN dbo.dim_date d ON d.date_id = h.date_id
    GROUP BY h.location_id
)
SELECT
    l.country,
    l.continent,
    FORMAT(l.population,   'N0')                         AS population,
    lh.latest_date                                       AS data_as_of,

    -- Hospital occupancy
    FORMAT(MAX(h.daily_occupancy_hosp),      'N0')       AS hosp_patients,
    FORMAT(MAX(h.daily_occupancy_hosp_per_1m),'N2')      AS hosp_per_million,

    -- ICU occupancy
    FORMAT(MAX(h.daily_occupancy_icu),       'N0')       AS icu_patients,
    FORMAT(MAX(h.daily_occupancy_icu_per_1m), 'N2')      AS icu_per_million,

    -- Weekly admissions
    FORMAT(MAX(h.weekly_admissions_hosp),    'N0')       AS weekly_hosp_admissions,
    FORMAT(MAX(h.weekly_admissions_hosp_per_1m), 'N2')   AS weekly_hosp_per_million,
    FORMAT(MAX(h.weekly_admissions_icu),     'N0')       AS weekly_icu_admissions,
    FORMAT(MAX(h.weekly_admissions_icu_per_1m),  'N2')   AS weekly_icu_per_million

FROM dbo.fact_hospitalization h
JOIN dbo.dim_location l  ON l.location_id  = h.location_id
JOIN dbo.dim_date     d  ON d.date_id      = h.date_id
JOIN latest_hosp      lh ON lh.location_id = h.location_id
WHERE l.continent <> '' AND l.continent IS NOT NULL
  AND d.date = lh.latest_date     -- only most recent row per country
GROUP BY l.country, l.continent, l.population, lh.latest_date
ORDER BY MAX(h.daily_occupancy_icu_per_1m) DESC;
