-- ============================================================
-- COVID-19 ETL — Post-Load Verification Stored Procedure
-- Run automatically as the last step of the SSIS package.
--
-- Usage:
--   EXEC usp_verify_etl_load;
--
-- Output:
--   1. Executive Summary — overall PASS/FAIL + row counts
--   2. Check Results — 12 checks with PASS/FAIL/notes
--   3. RAISERROR if any critical check fails (SSIS catches this)
--   4. Logs all results to etl_verification_log for history
-- ============================================================


-- ============================================================
-- STEP 1 — Create support tables if they do not exist
-- ============================================================

IF NOT EXISTS (SELECT 1 FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_NAME = 'etl_verification_log')
BEGIN
    CREATE TABLE etl_verification_log (
        log_id          INT IDENTITY(1,1) PRIMARY KEY,
        run_timestamp   DATETIME         NOT NULL DEFAULT GETDATE(),
        check_id        TINYINT          NOT NULL,
        check_name      NVARCHAR(100)    NOT NULL,
        status          NVARCHAR(10)     NOT NULL,
        failure_count   INT              NOT NULL,
        notes           NVARCHAR(500)    NULL
    );
END;
GO


-- ============================================================
-- STEP 2 — Stored Procedure
-- ============================================================

CREATE OR ALTER PROCEDURE usp_verify_etl_load
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @run_start DATETIME2 = CAST(GETDATE() AS DATE);

    -- Temp table for check results
    CREATE TABLE #results (
        check_id        TINYINT         NOT NULL,
        check_name      NVARCHAR(100)   NOT NULL,
        check_type      NVARCHAR(15)    NOT NULL,   -- Critical / Informational
        status          NVARCHAR(10)    NOT NULL,   -- PASS / FAIL
        failure_count   INT             NOT NULL,
        notes           NVARCHAR(500)   NULL
    );

    DECLARE @failures INT;
    DECLARE @notes    NVARCHAR(500);


    -- ============================================================
    -- CHECK 1 — Load Summary (Informational)
    -- Shows row counts + date ranges + partition distribution
    -- for every table in the warehouse.
    -- ============================================================
    DECLARE @dim_loc_count  INT = (SELECT COUNT(*)    FROM dbo.dim_location);
    DECLARE @dim_date_count INT = (SELECT COUNT(*)    FROM dbo.dim_date);
    DECLARE @dim_date_min   DATE = (SELECT MIN(date)  FROM dbo.dim_date);
    DECLARE @dim_date_max   DATE = (SELECT MAX(date)  FROM dbo.dim_date);

    DECLARE @cases_count    INT  = (SELECT COUNT(*)   FROM dbo.fact_covid_cases);
    DECLARE @cases_min_date DATE = (SELECT MIN(d.date) FROM dbo.fact_covid_cases f JOIN dbo.dim_date d ON d.date_id = f.date_id);
    DECLARE @cases_max_date DATE = (SELECT MAX(d.date) FROM dbo.fact_covid_cases f JOIN dbo.dim_date d ON d.date_id = f.date_id);

    DECLARE @vacc_count     INT  = (SELECT COUNT(*)   FROM dbo.fact_vaccination);
    DECLARE @vacc_min_date  DATE = (SELECT MIN(d.date) FROM dbo.fact_vaccination f JOIN dbo.dim_date d ON d.date_id = f.date_id);
    DECLARE @vacc_max_date  DATE = (SELECT MAX(d.date) FROM dbo.fact_vaccination f JOIN dbo.dim_date d ON d.date_id = f.date_id);

    DECLARE @hosp_count     INT  = (SELECT COUNT(*)   FROM dbo.fact_hospitalization);
    DECLARE @hosp_min_date  DATE = (SELECT MIN(d.date) FROM dbo.fact_hospitalization f JOIN dbo.dim_date d ON d.date_id = f.date_id);
    DECLARE @hosp_max_date  DATE = (SELECT MAX(d.date) FROM dbo.fact_hospitalization f JOIN dbo.dim_date d ON d.date_id = f.date_id);

    SET @notes = CONCAT(
        'dim_location=', @dim_loc_count, ' countries',
        ' | dim_date=', @dim_date_count, ' days (', @dim_date_min, ' to ', @dim_date_max, ')',
        ' | fact_covid_cases=', FORMAT(@cases_count,'N0'), ' rows (', @cases_min_date, ' to ', @cases_max_date, ')',
        ' | fact_vaccination=', FORMAT(@vacc_count,'N0'), ' rows (', @vacc_min_date, ' to ', @vacc_max_date, ')',
        ' | fact_hospitalization=', FORMAT(@hosp_count,'N0'), ' rows (', @hosp_min_date, ' to ', @hosp_max_date, ')'
    );

    INSERT INTO #results VALUES (1, 'Load Summary', 'Informational', 'PASS', 0, @notes);


    -- ============================================================
    -- CHECK 2 — Null Foreign Key Check (Critical)
    -- ============================================================
    SET @failures =
        (SELECT COUNT(*) FROM dbo.fact_covid_cases    WHERE location_id IS NULL OR date_id IS NULL) +
        (SELECT COUNT(*) FROM dbo.fact_vaccination     WHERE location_id IS NULL OR date_id IS NULL) +
        (SELECT COUNT(*) FROM dbo.fact_hospitalization WHERE location_id IS NULL OR date_id IS NULL);

    INSERT INTO #results VALUES (
        2, 'Null Foreign Key Check', 'Critical',
        CASE WHEN @failures = 0 THEN 'PASS' ELSE 'FAIL' END, @failures,
        CASE WHEN @failures > 0 THEN 'Rows with NULL location_id or date_id — Lookup no-match not properly routed' ELSE 'All FK columns populated' END
    );


    -- ============================================================
    -- CHECK 3 — Duplicate Key Check (Critical)
    -- ============================================================
    SET @failures =
        (SELECT COUNT(*) FROM (SELECT location_id, date_id FROM dbo.fact_covid_cases    GROUP BY location_id, date_id HAVING COUNT(*) > 1) x) +
        (SELECT COUNT(*) FROM (SELECT location_id, date_id FROM dbo.fact_vaccination     GROUP BY location_id, date_id HAVING COUNT(*) > 1) x) +
        (SELECT COUNT(*) FROM (SELECT location_id, date_id FROM dbo.fact_hospitalization GROUP BY location_id, date_id HAVING COUNT(*) > 1) x);

    INSERT INTO #results VALUES (
        3, 'Duplicate Key Check', 'Critical',
        CASE WHEN @failures = 0 THEN 'PASS' ELSE 'FAIL' END, @failures,
        CASE WHEN @failures > 0 THEN 'Duplicate (location_id, date_id) combinations found — TRUNCATE step may have been skipped' ELSE 'No duplicates' END
    );


    -- ============================================================
    -- CHECK 4 — Referential Integrity (Critical)
    -- ============================================================
    SET @failures =
        (SELECT COUNT(*) FROM dbo.fact_covid_cases    f WHERE NOT EXISTS (SELECT 1 FROM dbo.dim_location d WHERE d.location_id = f.location_id)) +
        (SELECT COUNT(*) FROM dbo.fact_covid_cases    f WHERE NOT EXISTS (SELECT 1 FROM dbo.dim_date     d WHERE d.date_id     = f.date_id    )) +
        (SELECT COUNT(*) FROM dbo.fact_vaccination     f WHERE NOT EXISTS (SELECT 1 FROM dbo.dim_location d WHERE d.location_id = f.location_id)) +
        (SELECT COUNT(*) FROM dbo.fact_vaccination     f WHERE NOT EXISTS (SELECT 1 FROM dbo.dim_date     d WHERE d.date_id     = f.date_id    )) +
        (SELECT COUNT(*) FROM dbo.fact_hospitalization f WHERE NOT EXISTS (SELECT 1 FROM dbo.dim_location d WHERE d.location_id = f.location_id)) +
        (SELECT COUNT(*) FROM dbo.fact_hospitalization f WHERE NOT EXISTS (SELECT 1 FROM dbo.dim_date     d WHERE d.date_id     = f.date_id    ));

    INSERT INTO #results VALUES (
        4, 'Referential Integrity', 'Critical',
        CASE WHEN @failures = 0 THEN 'PASS' ELSE 'FAIL' END, @failures,
        CASE WHEN @failures > 0 THEN 'Orphan FK rows found — dims may have reloaded with new identity values after facts were written' ELSE 'All FK references valid' END
    );


    -- ============================================================
    -- CHECK 5 — Aggregate Sanity (Informational)
    -- ============================================================
    DECLARE @sum_new_cases  FLOAT = (SELECT SUM(new_cases)  FROM dbo.fact_covid_cases);
    DECLARE @sum_new_deaths FLOAT = (SELECT SUM(new_deaths) FROM dbo.fact_covid_cases);
    DECLARE @max_total_cases FLOAT = (SELECT MAX(total_cases) FROM dbo.fact_covid_cases);
    DECLARE @sum_vacc       FLOAT = (SELECT SUM(total_vaccinations) FROM dbo.fact_vaccination);
    DECLARE @sum_hosp       FLOAT = (SELECT SUM(daily_occupancy_hosp) FROM dbo.fact_hospitalization);

    SET @notes = CONCAT(
        'SUM(new_cases)=', FORMAT(ISNULL(@sum_new_cases,0), 'N0'),
        ' | SUM(new_deaths)=', FORMAT(ISNULL(@sum_new_deaths,0), 'N0'),
        ' | MAX(total_cases)=', FORMAT(ISNULL(@max_total_cases,0), 'N0'),
        ' | SUM(total_vaccinations)=', FORMAT(ISNULL(@sum_vacc,0), 'N0'),
        ' | SUM(daily_occupancy_hosp)=', FORMAT(ISNULL(@sum_hosp,0), 'N0')
    );

    INSERT INTO #results VALUES (5, 'Aggregate Sanity', 'Informational', 'PASS', 0, @notes);


    -- ============================================================
    -- CHECK 6 — DQ Reject Audit (Informational)
    -- ============================================================
    DECLARE @rejected_rows INT = (SELECT COUNT(*) FROM dbo.dq_rejected_rows WHERE load_timestamp >= @run_start);

    INSERT INTO #results VALUES (
        6, 'DQ Reject Audit', 'Informational', 'PASS', @rejected_rows,
        CONCAT('Total rejected rows this run: ', @rejected_rows,
               ' — query dq_rejected_rows filtered by today''s date for breakdown by rule_id')
    );


    -- ============================================================
    -- CHECK 7 — Negative Value Check (Critical)
    -- ============================================================
    SET @failures =
        (SELECT COUNT(*) FROM dbo.fact_covid_cases    WHERE new_cases  < 0) +
        (SELECT COUNT(*) FROM dbo.fact_covid_cases    WHERE new_deaths < 0) +
        (SELECT COUNT(*) FROM dbo.fact_vaccination    WHERE daily_vaccinations_smoothed < 0) +
        (SELECT COUNT(*) FROM dbo.fact_hospitalization WHERE daily_occupancy_hosp < 0) +
        (SELECT COUNT(*) FROM dbo.fact_hospitalization WHERE daily_occupancy_icu  < 0);

    INSERT INTO #results VALUES (
        7, 'Negative Value Check', 'Critical',
        CASE WHEN @failures = 0 THEN 'PASS' ELSE 'FAIL' END, @failures,
        CASE WHEN @failures > 0 THEN 'Negative metric values found — DQ-04/DQ-05 Conditional Split may not have fired' ELSE 'No negative values' END
    );


    -- ============================================================
    -- CHECK 8 — Date Coverage (Critical)
    -- dim_date must have every date from 2020-01-01 to today.
    -- ============================================================
    ;WITH date_series AS (
        SELECT CAST('2020-01-01' AS DATE) AS expected_date
        UNION ALL
        SELECT DATEADD(DAY, 1, expected_date) FROM date_series WHERE expected_date < CAST(GETDATE() AS DATE)
    )
    SELECT @failures = COUNT(*)
    FROM date_series ds
    WHERE NOT EXISTS (SELECT 1 FROM dbo.dim_date d WHERE d.date = ds.expected_date)
    OPTION (MAXRECURSION 3000);

    INSERT INTO #results VALUES (
        8, 'Date Coverage Check', 'Critical',
        CASE WHEN @failures = 0 THEN 'PASS' ELSE 'FAIL' END, @failures,
        CASE WHEN @failures > 0
             THEN CONCAT(@failures, ' missing dates in dim_date — Script Task may have used wrong start date or IDENTITY not reseeded')
             ELSE CONCAT('dim_date complete: 2020-01-01 to ', CAST(GETDATE() AS DATE), ' — no gaps') END
    );


    -- ============================================================
    -- CHECK 9 — Monotonic Totals (Informational)
    -- ============================================================
    SET @failures = (
        SELECT COUNT(*) FROM (
            SELECT f.total_cases,
                   LAG(f.total_cases)  OVER (PARTITION BY f.location_id ORDER BY d.date) AS prev_cases,
                   f.total_deaths,
                   LAG(f.total_deaths) OVER (PARTITION BY f.location_id ORDER BY d.date) AS prev_deaths
            FROM dbo.fact_covid_cases f JOIN dbo.dim_date d ON d.date_id = f.date_id
        ) x
        WHERE total_cases < prev_cases OR total_deaths < prev_deaths
    );

    INSERT INTO #results VALUES (
        9, 'Monotonic Totals Check', 'Informational',
        CASE WHEN @failures = 0 THEN 'PASS' ELSE 'WARN' END, @failures,
        CASE WHEN @failures > 0
             THEN CONCAT(@failures, ' country-days where cumulative totals decreased — likely OWID historical correction, not a pipeline error')
             ELSE 'Cumulative totals never decrease — data consistent' END
    );


    -- ============================================================
    -- CHECK 10 — Rejection Threshold (Critical)
    -- Fails if unexpected rejects exceed threshold per source.
    -- ============================================================
    DECLARE @reject_threshold_fail BIT = 0;
    DECLARE @reject_threshold_notes NVARCHAR(500) = '';

    DECLARE @cases_loaded   INT   = (SELECT COUNT(*) FROM dbo.fact_covid_cases);
    DECLARE @cases_rejected INT   = (SELECT COUNT(*) FROM dbo.dq_rejected_rows WHERE source_file = 'owid_covid_compact.csv' AND rule_id <> 'DQ-03' AND load_timestamp >= @run_start);
    DECLARE @cases_pct      FLOAT = CAST(@cases_rejected AS FLOAT) / NULLIF(@cases_loaded + @cases_rejected, 0);
    IF @cases_pct > 0.05 BEGIN SET @reject_threshold_fail = 1; SET @reject_threshold_notes += CONCAT('fact_covid_cases: ', FORMAT(@cases_pct*100,'N1'), '% rejected (limit 5%). '); END;

    DECLARE @vacc_loaded    INT   = (SELECT COUNT(*) FROM dbo.fact_vaccination);
    DECLARE @vacc_rejected  INT   = (SELECT COUNT(*) FROM dbo.dq_rejected_rows WHERE source_file = 'vaccinations_global.csv' AND load_timestamp >= @run_start);
    DECLARE @vacc_pct       FLOAT = CAST(@vacc_rejected AS FLOAT) / NULLIF(@vacc_loaded + @vacc_rejected, 0);
    IF @vacc_pct > 0.10 BEGIN SET @reject_threshold_fail = 1; SET @reject_threshold_notes += CONCAT('fact_vaccination: ', FORMAT(@vacc_pct*100,'N1'), '% rejected (limit 10%). '); END;

    DECLARE @hosp_loaded    INT   = (SELECT COUNT(*) FROM dbo.fact_hospitalization);
    DECLARE @hosp_rejected  INT   = (SELECT COUNT(*) FROM dbo.dq_rejected_rows WHERE source_file = 'hospital.csv' AND load_timestamp >= @run_start);
    DECLARE @hosp_pct       FLOAT = CAST(@hosp_rejected AS FLOAT) / NULLIF(@hosp_loaded + @hosp_rejected, 0);
    IF @hosp_pct > 0.05 BEGIN SET @reject_threshold_fail = 1; SET @reject_threshold_notes += CONCAT('fact_hospitalization: ', FORMAT(@hosp_pct*100,'N1'), '% rejected (limit 5%). '); END;

    IF LEN(@reject_threshold_notes) = 0
        SET @reject_threshold_notes = CONCAT(
            'fact_covid_cases=', FORMAT(ISNULL(@cases_pct,0)*100,'N1'), '% | ',
            'fact_vaccination=', FORMAT(ISNULL(@vacc_pct, 0)*100,'N1'), '% | ',
            'fact_hospitalization=', FORMAT(ISNULL(@hosp_pct,0)*100,'N1'), '% — all within thresholds'
        );

    INSERT INTO #results VALUES (
        10, 'Rejection Threshold', 'Critical',
        CASE WHEN @reject_threshold_fail = 1 THEN 'FAIL' ELSE 'PASS' END,
        @cases_rejected + @vacc_rejected + @hosp_rejected,
        @reject_threshold_notes
    );


    -- ============================================================
    -- CHECK 11 — Soft Outlier Detection (Informational)
    -- ============================================================
    DECLARE @ol_notes NVARCHAR(500) = '';
    DECLARE @ol_count INT = 0;

    DECLARE @spike_count INT = (SELECT COUNT(*) FROM dbo.fact_covid_cases WHERE new_cases > 1000000);
    IF @spike_count > 0 BEGIN SET @ol_count += @spike_count; SET @ol_notes += CONCAT('OL-01: ', @spike_count, ' days with new_cases > 1M. '); END;

    DECLARE @rt_count INT = (SELECT COUNT(*) FROM dbo.fact_covid_cases WHERE reproduction_rate > 15);
    IF @rt_count > 0 BEGIN SET @ol_count += @rt_count; SET @ol_notes += CONCAT('OL-02: ', @rt_count, ' rows reproduction_rate > 15. '); END;

    DECLARE @vacc_logic_count INT = (SELECT COUNT(*) FROM dbo.fact_vaccination WHERE people_vaccinated IS NOT NULL AND people_fully_vaccinated IS NOT NULL AND people_vaccinated < people_fully_vaccinated);
    IF @vacc_logic_count > 0 BEGIN SET @ol_count += @vacc_logic_count; SET @ol_notes += CONCAT('OL-03: ', @vacc_logic_count, ' rows fully_vaccinated > vaccinated. '); END;

    DECLARE @pop_exceed_count INT = (SELECT COUNT(*) FROM dbo.fact_covid_cases f JOIN dbo.dim_location l ON l.location_id = f.location_id WHERE f.new_cases IS NOT NULL AND l.population IS NOT NULL AND f.new_cases > l.population);
    IF @pop_exceed_count > 0 BEGIN SET @ol_count += @pop_exceed_count; SET @ol_notes += CONCAT('OL-04: ', @pop_exceed_count, ' rows new_cases > population. '); END;

    IF LEN(@ol_notes) = 0 SET @ol_notes = 'No outliers detected — all values within expected ranges.';

    INSERT INTO #results VALUES (11, 'Soft Outlier Detection', 'Informational', 'PASS', @ol_count, @ol_notes);


    -- ============================================================
    -- CHECK 12 — Partition Health (Informational)
    -- Confirms rows are distributed across all 7 year partitions.
    -- ============================================================
    DECLARE @empty_partitions INT = (
        SELECT COUNT(*) FROM sys.partitions p
        JOIN sys.tables t ON t.object_id = p.object_id
        WHERE t.name = 'fact_covid_cases' AND p.index_id = 1 AND p.rows = 0
    );

    DECLARE @partition_summary NVARCHAR(500) = (
        SELECT STRING_AGG(CONCAT('P', p.partition_number, '=', FORMAT(p.rows,'N0')), ' | ')
        FROM sys.partitions p
        JOIN sys.tables t ON t.object_id = p.object_id
        WHERE t.name = 'fact_covid_cases' AND p.index_id = 1
    );

    INSERT INTO #results VALUES (
        12, 'Partition Health', 'Informational', 'PASS', @empty_partitions,
        CONCAT('fact_covid_cases partition rows: ', @partition_summary,
               CASE WHEN @empty_partitions > 0 THEN ' — WARNING: ' + CAST(@empty_partitions AS VARCHAR) + ' empty partition(s)' ELSE '' END)
    );


    -- ============================================================
    -- Log results
    -- ============================================================
    INSERT INTO etl_verification_log (check_id, check_name, status, failure_count, notes)
    SELECT check_id, check_name, status, failure_count, notes FROM #results;


    -- ============================================================
    -- Output 1: Executive Summary
    -- ============================================================
    DECLARE @critical_failures INT = (SELECT COUNT(*) FROM #results WHERE status = 'FAIL' AND check_type = 'Critical');
    DECLARE @overall_status NVARCHAR(10) = CASE WHEN @critical_failures = 0 THEN 'PASS' ELSE 'FAIL' END;

    SELECT
        @overall_status                             AS [Overall Status],
        @critical_failures                          AS [Critical Failures],
        FORMAT(@cases_count, 'N0')                  AS [fact_covid_cases rows],
        FORMAT(@vacc_count,  'N0')                  AS [fact_vaccination rows],
        FORMAT(@hosp_count,  'N0')                  AS [fact_hospitalization rows],
        FORMAT(@dim_loc_count, 'N0')                AS [dim_location countries],
        FORMAT(@dim_date_count, 'N0')               AS [dim_date days],
        CAST(@run_start AS NVARCHAR(20))            AS [Run Date];


    -- ============================================================
    -- Output 2: Full Check Results
    -- ============================================================
    SELECT
        check_id        AS [#],
        check_type      AS [Type],
        check_name      AS [Check],
        status          AS [Status],
        failure_count   AS [Count],
        ISNULL(notes,'') AS [Notes]
    FROM #results
    ORDER BY check_id;


    -- ============================================================
    -- Raise error if any critical check failed
    -- ============================================================
    IF @critical_failures > 0
    BEGIN
        DECLARE @failed_checks NVARCHAR(500);
        SELECT @failed_checks = STRING_AGG(check_name, ', ')
        FROM #results WHERE status = 'FAIL' AND check_type = 'Critical';
        RAISERROR('ETL verification FAILED. Critical checks: %s', 16, 1, @failed_checks);
    END;

    DROP TABLE #results;
END;
GO
