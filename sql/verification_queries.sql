-- ============================================================
-- COVID-19 ETL — Post-Load Verification Queries
-- Run in SSMS after every SSIS package execution.
-- All 9 checks must return 0 failures before proceeding.
-- ============================================================

-- ============================================================
-- CHECK 1 — Row Count Reconciliation
-- Expected: counts match what SSIS package log reported
-- ============================================================

SELECT 'dim_location'      AS table_name, COUNT(*) AS row_count FROM dim_location
UNION ALL
SELECT 'dim_date'          AS table_name, COUNT(*) AS row_count FROM dim_date
UNION ALL
SELECT 'fact_covid_cases'  AS table_name, COUNT(*) AS row_count FROM fact_covid_cases
UNION ALL
SELECT 'fact_vaccination'  AS table_name, COUNT(*) AS row_count FROM fact_vaccination
UNION ALL
SELECT 'fact_hospitalization' AS table_name, COUNT(*) AS row_count FROM fact_hospitalization;

-- ============================================================
-- CHECK 2 — Null Foreign Key Check
-- Expected: 0 rows for all queries
-- ============================================================

SELECT 'fact_covid_cases — null location_id' AS check_name, COUNT(*) AS failures
FROM fact_covid_cases WHERE location_id IS NULL
UNION ALL
SELECT 'fact_covid_cases — null date_id', COUNT(*)
FROM fact_covid_cases WHERE date_id IS NULL
UNION ALL
SELECT 'fact_vaccination — null location_id', COUNT(*)
FROM fact_vaccination WHERE location_id IS NULL
UNION ALL
SELECT 'fact_vaccination — null date_id', COUNT(*)
FROM fact_vaccination WHERE date_id IS NULL
UNION ALL
SELECT 'fact_hospitalization — null location_id', COUNT(*)
FROM fact_hospitalization WHERE location_id IS NULL
UNION ALL
SELECT 'fact_hospitalization — null date_id', COUNT(*)
FROM fact_hospitalization WHERE date_id IS NULL;

-- ============================================================
-- CHECK 3 — Duplicate Key Check
-- Expected: 0 rows for all queries
-- ============================================================

SELECT 'fact_covid_cases duplicates' AS check_name, COUNT(*) AS failures
FROM (
    SELECT location_id, date_id, COUNT(*) AS cnt
    FROM fact_covid_cases
    GROUP BY location_id, date_id
    HAVING COUNT(*) > 1
) AS dupes
UNION ALL
SELECT 'fact_vaccination duplicates', COUNT(*)
FROM (
    SELECT location_id, date_id, COUNT(*) AS cnt
    FROM fact_vaccination
    GROUP BY location_id, date_id
    HAVING COUNT(*) > 1
) AS dupes
UNION ALL
SELECT 'fact_hospitalization duplicates', COUNT(*)
FROM (
    SELECT location_id, date_id, COUNT(*) AS cnt
    FROM fact_hospitalization
    GROUP BY location_id, date_id
    HAVING COUNT(*) > 1
) AS dupes;

-- ============================================================
-- CHECK 4 — Referential Integrity Check
-- Expected: 0 rows for all queries
-- ============================================================

SELECT 'fact_covid_cases — orphan location_id' AS check_name, COUNT(*) AS failures
FROM fact_covid_cases f
WHERE NOT EXISTS (SELECT 1 FROM dim_location d WHERE d.location_id = f.location_id)
UNION ALL
SELECT 'fact_covid_cases — orphan date_id', COUNT(*)
FROM fact_covid_cases f
WHERE NOT EXISTS (SELECT 1 FROM dim_date d WHERE d.date_id = f.date_id)
UNION ALL
SELECT 'fact_vaccination — orphan location_id', COUNT(*)
FROM fact_vaccination f
WHERE NOT EXISTS (SELECT 1 FROM dim_location d WHERE d.location_id = f.location_id)
UNION ALL
SELECT 'fact_vaccination — orphan date_id', COUNT(*)
FROM fact_vaccination f
WHERE NOT EXISTS (SELECT 1 FROM dim_date d WHERE d.date_id = f.date_id)
UNION ALL
SELECT 'fact_hospitalization — orphan location_id', COUNT(*)
FROM fact_hospitalization f
WHERE NOT EXISTS (SELECT 1 FROM dim_location d WHERE d.location_id = f.location_id)
UNION ALL
SELECT 'fact_hospitalization — orphan date_id', COUNT(*)
FROM fact_hospitalization f
WHERE NOT EXISTS (SELECT 1 FROM dim_date d WHERE d.date_id = f.date_id);

-- ============================================================
-- CHECK 5 — Aggregate Reconciliation
-- Compare warehouse totals — review against SSIS package log
-- ============================================================

SELECT
    'fact_covid_cases'              AS table_name,
    SUM(new_cases)                  AS total_new_cases,
    SUM(new_deaths)                 AS total_new_deaths,
    MAX(total_cases)                AS max_total_cases,
    MAX(total_deaths)               AS max_total_deaths
FROM fact_covid_cases;

SELECT
    'fact_vaccination'              AS table_name,
    SUM(daily_vaccinations_smoothed) AS total_daily_vaccinations,
    MAX(total_vaccinations)         AS max_total_vaccinations,
    SUM(people_unvaccinated)        AS total_unvaccinated
FROM fact_vaccination;

SELECT
    'fact_hospitalization'          AS table_name,
    SUM(daily_occupancy_hosp)       AS total_hosp_occupancy,
    SUM(daily_occupancy_icu)        AS total_icu_occupancy,
    SUM(weekly_admissions_hosp)     AS total_hosp_admissions
FROM fact_hospitalization;

-- ============================================================
-- CHECK 6 — DQ Reject Audit
-- Review rejected rows by rule and source
-- ============================================================

SELECT
    rule_id,
    source_file,
    COUNT(*)            AS rejected_rows,
    MIN(load_timestamp) AS first_seen,
    MAX(load_timestamp) AS last_seen
FROM dq_rejected_rows
GROUP BY rule_id, source_file
ORDER BY rejected_rows DESC;

-- ============================================================
-- CHECK 7 — Negative Value Check
-- Expected: 0 rows
-- ============================================================

SELECT 'negative new_cases' AS check_name, COUNT(*) AS failures
FROM fact_covid_cases WHERE new_cases < 0
UNION ALL
SELECT 'negative new_deaths', COUNT(*)
FROM fact_covid_cases WHERE new_deaths < 0
UNION ALL
SELECT 'negative daily_vaccinations_smoothed', COUNT(*)
FROM fact_vaccination WHERE daily_vaccinations_smoothed < 0
UNION ALL
SELECT 'negative daily_occupancy_hosp', COUNT(*)
FROM fact_hospitalization WHERE daily_occupancy_hosp < 0
UNION ALL
SELECT 'negative daily_occupancy_icu', COUNT(*)
FROM fact_hospitalization WHERE daily_occupancy_icu < 0;

-- ============================================================
-- CHECK 8 — Date Coverage Check
-- Expected: 0 gaps between 2020-01-01 and today
-- ============================================================

WITH date_series AS (
    SELECT CAST('2020-01-01' AS DATE) AS expected_date
    UNION ALL
    SELECT DATEADD(DAY, 1, expected_date)
    FROM date_series
    WHERE expected_date < CAST(GETDATE() AS DATE)
)
SELECT COUNT(*) AS missing_dates
FROM date_series ds
WHERE NOT EXISTS (
    SELECT 1 FROM dim_date d WHERE d.date = ds.expected_date
)
OPTION (MAXRECURSION 3000);

-- ============================================================
-- CHECK 9 — Monotonic Totals Check
-- Expected: 0 rows (total_cases should never decrease day over day)
-- ============================================================

WITH daily_totals AS (
    SELECT
        f.location_id,
        d.date,
        f.total_cases,
        f.total_deaths,
        LAG(f.total_cases)  OVER (PARTITION BY f.location_id ORDER BY d.date) AS prev_total_cases,
        LAG(f.total_deaths) OVER (PARTITION BY f.location_id ORDER BY d.date) AS prev_total_deaths
    FROM fact_covid_cases f
    JOIN dim_date d ON d.date_id = f.date_id
)
SELECT
    l.country,
    dt.date,
    dt.total_cases,
    dt.prev_total_cases,
    dt.total_cases - dt.prev_total_cases AS decrease_amount,
    'total_cases decreased' AS anomaly_type
FROM daily_totals dt
JOIN dim_location l ON l.location_id = dt.location_id
WHERE dt.total_cases < dt.prev_total_cases

UNION ALL

SELECT
    l.country,
    dt.date,
    dt.total_deaths,
    dt.prev_total_deaths,
    dt.total_deaths - dt.prev_total_deaths AS decrease_amount,
    'total_deaths decreased'
FROM daily_totals dt
JOIN dim_location l ON l.location_id = dt.location_id
WHERE dt.total_deaths < dt.prev_total_deaths

ORDER BY ABS(decrease_amount) DESC;

-- ============================================================
-- SUMMARY — Quick pass/fail overview
-- Run this last. All failure counts should be 0.
-- ============================================================

SELECT '2 — Null FK'           AS check_name,
    (SELECT COUNT(*) FROM fact_covid_cases WHERE location_id IS NULL OR date_id IS NULL) +
    (SELECT COUNT(*) FROM fact_vaccination WHERE location_id IS NULL OR date_id IS NULL) +
    (SELECT COUNT(*) FROM fact_hospitalization WHERE location_id IS NULL OR date_id IS NULL)
    AS failures
UNION ALL
SELECT '3 — Duplicates',
    (SELECT COUNT(*) FROM (SELECT location_id, date_id FROM fact_covid_cases GROUP BY location_id, date_id HAVING COUNT(*) > 1) x) +
    (SELECT COUNT(*) FROM (SELECT location_id, date_id FROM fact_vaccination GROUP BY location_id, date_id HAVING COUNT(*) > 1) x) +
    (SELECT COUNT(*) FROM (SELECT location_id, date_id FROM fact_hospitalization GROUP BY location_id, date_id HAVING COUNT(*) > 1) x)
UNION ALL
SELECT '7 — Negative values',
    (SELECT COUNT(*) FROM fact_covid_cases WHERE new_cases < 0 OR new_deaths < 0) +
    (SELECT COUNT(*) FROM fact_vaccination WHERE daily_vaccinations_smoothed < 0) +
    (SELECT COUNT(*) FROM fact_hospitalization WHERE daily_occupancy_hosp < 0 OR daily_occupancy_icu < 0)
UNION ALL
SELECT '9 — Monotonic totals decrease',
    (SELECT COUNT(*) FROM (
        SELECT f.location_id, f.total_cases,
               LAG(f.total_cases) OVER (PARTITION BY f.location_id ORDER BY d.date) AS prev
        FROM fact_covid_cases f JOIN dim_date d ON d.date_id = f.date_id
    ) x WHERE total_cases < prev);
