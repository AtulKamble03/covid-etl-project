-- ============================================================
-- REPORT 8 — Testing
-- Business Question: What is the positivity rate per country?
-- Which countries show potential under-reporting signals?
--
-- Sliceable by: Country, Continent, Risk Signal
-- Key metrics: Total tests, positivity rate, tests per case
-- IMPORTANT: 82-87% null — limited to countries reporting to OWID
-- ============================================================

USE covid_dw;
GO

SELECT
    l.country,
    l.continent,

    -- Test volume
    FORMAT(SUM(f.new_tests_smoothed), 'N0')              AS total_tests_smoothed,
    FORMAT(AVG(f.tests_per_case),     'N1')              AS avg_tests_per_case,
    COUNT(CASE WHEN f.new_tests_smoothed IS NOT NULL
               THEN 1 END)                               AS days_reporting,

    -- Positivity rate (0-1 scale in source — multiply by 100 for %)
    FORMAT(AVG(f.positive_rate) * 100,  'N2') + '%'      AS avg_positivity_rate,
    FORMAT(MAX(f.positive_rate) * 100,  'N2') + '%'      AS peak_positivity_rate,
    FORMAT(MIN(f.positive_rate) * 100,  'N2') + '%'      AS min_positivity_rate,

    -- Risk signal based on WHO recommendation (< 5% = adequate testing)
    CASE
        WHEN AVG(f.positive_rate) IS NULL   THEN 'NO DATA'
        WHEN AVG(f.positive_rate) > 0.10   THEN 'HIGH RISK — >10% positivity (likely under-reporting)'
        WHEN AVG(f.positive_rate) > 0.05   THEN 'ELEVATED — 5-10% positivity (watch closely)'
        ELSE                                    'ACCEPTABLE — <5% positivity (adequate testing)'
    END                                                  AS risk_signal

FROM dbo.fact_covid_cases f
JOIN dbo.dim_location l ON l.location_id = f.location_id
WHERE l.continent <> '' AND l.continent IS NOT NULL
  AND f.new_tests_smoothed IS NOT NULL    -- only rows where testing data exists
GROUP BY l.country, l.continent
HAVING COUNT(CASE WHEN f.new_tests_smoothed IS NOT NULL THEN 1 END) > 30  -- min 30 days of data
ORDER BY AVG(f.positive_rate) DESC;
