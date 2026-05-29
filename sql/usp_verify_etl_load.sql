-- ============================================================
-- COVID-19 ETL — Verification Stored Procedure
-- Run automatically as the last step of the SSIS package.
--
-- Usage:
--   EXEC usp_verify_etl_load;
--
-- Returns:
--   Result set with PASS/FAIL per check.
--   Logs results to etl_verification_log for history.
--   Raises an error if any critical check fails — SSIS
--   will catch this and mark the package as failed.
-- ============================================================


-- ============================================================
-- STEP 1 — Create verification log table if it does not exist
-- Run this once before the first package execution.
-- ============================================================

IF NOT EXISTS (
    SELECT 1 FROM INFORMATION_SCHEMA.TABLES
    WHERE TABLE_NAME = 'etl_verification_log'
)
BEGIN
    CREATE TABLE etl_verification_log (
        log_id          INT IDENTITY(1,1) PRIMARY KEY,
        run_timestamp   DATETIME         NOT NULL DEFAULT GETDATE(),
        check_id        TINYINT          NOT NULL,
        check_name      NVARCHAR(100)    NOT NULL,
        status          NVARCHAR(10)     NOT NULL,  -- PASS or FAIL
        failure_count   INT              NOT NULL,
        notes           NVARCHAR(500)    NULL
    );
END;
GO


-- ============================================================
-- STEP 2 — Create or replace the stored procedure
-- ============================================================

CREATE OR ALTER PROCEDURE usp_verify_etl_load
AS
BEGIN
    SET NOCOUNT ON;

    -- Temp table to collect results for this run
    CREATE TABLE #results (
        check_id        TINYINT         NOT NULL,
        check_name      NVARCHAR(100)   NOT NULL,
        status          NVARCHAR(10)    NOT NULL,
        failure_count   INT             NOT NULL,
        notes           NVARCHAR(500)   NULL
    );

    DECLARE @failures   INT;
    DECLARE @notes      NVARCHAR(500);

    -- --------------------------------------------------------
    -- CHECK 1 — Row Count Reconciliation (informational)
    -- --------------------------------------------------------
    DECLARE @dim_location_count     INT = (SELECT COUNT(*) FROM dim_location);
    DECLARE @dim_date_count         INT = (SELECT COUNT(*) FROM dim_date);
    DECLARE @fact_cases_count       INT = (SELECT COUNT(*) FROM fact_covid_cases);
    DECLARE @fact_vacc_count        INT = (SELECT COUNT(*) FROM fact_vaccination);
    DECLARE @fact_hosp_count        INT = (SELECT COUNT(*) FROM fact_hospitalization);

    SET @notes = CONCAT(
        'dim_location=', @dim_location_count,
        ' | dim_date=', @dim_date_count,
        ' | fact_covid_cases=', @fact_cases_count,
        ' | fact_vaccination=', @fact_vacc_count,
        ' | fact_hospitalization=', @fact_hosp_count
    );

    INSERT INTO #results VALUES (1, 'Row Count Reconciliation', 'PASS', 0, @notes);

    -- --------------------------------------------------------
    -- CHECK 2 — Null Foreign Key Check
    -- --------------------------------------------------------
    SET @failures =
        (SELECT COUNT(*) FROM fact_covid_cases      WHERE location_id IS NULL OR date_id IS NULL) +
        (SELECT COUNT(*) FROM fact_vaccination       WHERE location_id IS NULL OR date_id IS NULL) +
        (SELECT COUNT(*) FROM fact_hospitalization   WHERE location_id IS NULL OR date_id IS NULL);

    INSERT INTO #results VALUES (
        2, 'Null Foreign Key Check',
        CASE WHEN @failures = 0 THEN 'PASS' ELSE 'FAIL' END,
        @failures,
        CASE WHEN @failures > 0 THEN 'SSIS Lookup did not resolve some country/date keys — check no-match output' ELSE NULL END
    );

    -- --------------------------------------------------------
    -- CHECK 3 — Duplicate Key Check
    -- --------------------------------------------------------
    SET @failures =
        (SELECT COUNT(*) FROM (
            SELECT location_id, date_id FROM fact_covid_cases
            GROUP BY location_id, date_id HAVING COUNT(*) > 1) x) +
        (SELECT COUNT(*) FROM (
            SELECT location_id, date_id FROM fact_vaccination
            GROUP BY location_id, date_id HAVING COUNT(*) > 1) x) +
        (SELECT COUNT(*) FROM (
            SELECT location_id, date_id FROM fact_hospitalization
            GROUP BY location_id, date_id HAVING COUNT(*) > 1) x);

    INSERT INTO #results VALUES (
        3, 'Duplicate Key Check',
        CASE WHEN @failures = 0 THEN 'PASS' ELSE 'FAIL' END,
        @failures,
        CASE WHEN @failures > 0 THEN 'Package may have run twice without truncating — check SSIS truncate step' ELSE NULL END
    );

    -- --------------------------------------------------------
    -- CHECK 4 — Referential Integrity Check
    -- --------------------------------------------------------
    SET @failures =
        (SELECT COUNT(*) FROM fact_covid_cases f
            WHERE NOT EXISTS (SELECT 1 FROM dim_location d WHERE d.location_id = f.location_id)) +
        (SELECT COUNT(*) FROM fact_covid_cases f
            WHERE NOT EXISTS (SELECT 1 FROM dim_date d WHERE d.date_id = f.date_id)) +
        (SELECT COUNT(*) FROM fact_vaccination f
            WHERE NOT EXISTS (SELECT 1 FROM dim_location d WHERE d.location_id = f.location_id)) +
        (SELECT COUNT(*) FROM fact_vaccination f
            WHERE NOT EXISTS (SELECT 1 FROM dim_date d WHERE d.date_id = f.date_id)) +
        (SELECT COUNT(*) FROM fact_hospitalization f
            WHERE NOT EXISTS (SELECT 1 FROM dim_location d WHERE d.location_id = f.location_id)) +
        (SELECT COUNT(*) FROM fact_hospitalization f
            WHERE NOT EXISTS (SELECT 1 FROM dim_date d WHERE d.date_id = f.date_id));

    INSERT INTO #results VALUES (
        4, 'Referential Integrity Check',
        CASE WHEN @failures = 0 THEN 'PASS' ELSE 'FAIL' END,
        @failures,
        CASE WHEN @failures > 0 THEN 'Orphan FK references found — dimensions may not have loaded before facts' ELSE NULL END
    );

    -- --------------------------------------------------------
    -- CHECK 5 — Aggregate Reconciliation (informational)
    -- --------------------------------------------------------
    DECLARE @total_new_cases    FLOAT = (SELECT SUM(new_cases)  FROM fact_covid_cases);
    DECLARE @total_new_deaths   FLOAT = (SELECT SUM(new_deaths) FROM fact_covid_cases);
    DECLARE @max_total_cases    FLOAT = (SELECT MAX(total_cases) FROM fact_covid_cases);

    SET @notes = CONCAT(
        'SUM(new_cases)=',  CAST(ISNULL(@total_new_cases,  0) AS NVARCHAR(50)),
        ' | SUM(new_deaths)=', CAST(ISNULL(@total_new_deaths, 0) AS NVARCHAR(50)),
        ' | MAX(total_cases)=', CAST(ISNULL(@max_total_cases,  0) AS NVARCHAR(50))
    );

    INSERT INTO #results VALUES (5, 'Aggregate Reconciliation', 'PASS', 0, @notes);

    -- --------------------------------------------------------
    -- CHECK 6 — DQ Reject Audit (informational)
    -- --------------------------------------------------------
    DECLARE @run_start     DATETIME2 = CAST(GETDATE() AS DATE);

    DECLARE @rejected_rows INT = (
        SELECT COUNT(*) FROM dq_rejected_rows
        WHERE load_timestamp >= @run_start
    );

    SET @notes = CONCAT(
        'Total rows rejected in this run: ', @rejected_rows,
        ' (includes all rules across all source files)'
    );

    INSERT INTO #results VALUES (6, 'DQ Reject Audit', 'PASS', @rejected_rows, @notes);

    -- --------------------------------------------------------
    -- CHECK 7 — Negative Value Check
    -- --------------------------------------------------------
    SET @failures =
        (SELECT COUNT(*) FROM fact_covid_cases    WHERE new_cases  < 0) +
        (SELECT COUNT(*) FROM fact_covid_cases    WHERE new_deaths < 0) +
        (SELECT COUNT(*) FROM fact_vaccination    WHERE daily_vaccinations_smoothed < 0) +
        (SELECT COUNT(*) FROM fact_hospitalization WHERE daily_occupancy_hosp < 0) +
        (SELECT COUNT(*) FROM fact_hospitalization WHERE daily_occupancy_icu  < 0);

    INSERT INTO #results VALUES (
        7, 'Negative Value Check',
        CASE WHEN @failures = 0 THEN 'PASS' ELSE 'FAIL' END,
        @failures,
        CASE WHEN @failures > 0 THEN 'DQ rules DQ-04/DQ-05 did not fire — check SSIS Conditional Split' ELSE NULL END
    );

    -- --------------------------------------------------------
    -- CHECK 8 — Date Coverage Check
    -- --------------------------------------------------------
    -- CTE cannot be used inside SET @var = (subquery) in SQL Server.
    -- Use SELECT @var = ... directly from the CTE instead.
    ;WITH date_series AS (
        SELECT CAST('2020-01-01' AS DATE) AS expected_date
        UNION ALL
        SELECT DATEADD(DAY, 1, expected_date)
        FROM date_series
        WHERE expected_date < CAST(GETDATE() AS DATE)
    )
    SELECT @failures = COUNT(*)
    FROM date_series ds
    WHERE NOT EXISTS (SELECT 1 FROM dim_date d WHERE d.date = ds.expected_date)
    OPTION (MAXRECURSION 3000);

    INSERT INTO #results VALUES (
        8, 'Date Coverage Check',
        CASE WHEN @failures = 0 THEN 'PASS' ELSE 'FAIL' END,
        @failures,
        CASE WHEN @failures > 0 THEN CONCAT(@failures, ' missing dates in dim_date — re-run dim_date generation Script Task') ELSE NULL END
    );

    -- --------------------------------------------------------
    -- CHECK 9 — Monotonic Totals Check
    -- --------------------------------------------------------
    SET @failures = (
        SELECT COUNT(*) FROM (
            SELECT
                f.total_cases,
                LAG(f.total_cases) OVER (PARTITION BY f.location_id ORDER BY d.date) AS prev_total_cases,
                f.total_deaths,
                LAG(f.total_deaths) OVER (PARTITION BY f.location_id ORDER BY d.date) AS prev_total_deaths
            FROM fact_covid_cases f
            JOIN dim_date d ON d.date_id = f.date_id
        ) x
        WHERE total_cases < prev_total_cases
           OR total_deaths < prev_total_deaths
    );

    INSERT INTO #results VALUES (
        9, 'Monotonic Totals Check',
        CASE WHEN @failures = 0 THEN 'PASS' ELSE 'FAIL' END,
        @failures,
        CASE WHEN @failures > 0 THEN 'OWID may have revised historical data downward — log as known anomaly' ELSE NULL END
    );

    -- --------------------------------------------------------
    -- CHECK 10 — Rejection Threshold Check (critical)
    -- Fails the package if unexpected rejects exceed the
    -- acceptable % per source file. DQ-03 rejects are excluded
    -- from fact_covid_cases as they are expected aggregate removals.
    -- Thresholds: 5% for compact + hospital, 10% for vaccinations.
    -- --------------------------------------------------------
    DECLARE @reject_threshold_fail BIT = 0;
    DECLARE @reject_threshold_notes NVARCHAR(500) = '';

    -- fact_covid_cases (owid_covid_compact.csv) — 5% threshold, exclude DQ-03
    DECLARE @cases_loaded   INT   = (SELECT COUNT(*) FROM dbo.fact_covid_cases);
    DECLARE @cases_rejected INT   = (SELECT COUNT(*) FROM dbo.dq_rejected_rows
                                     WHERE source_file = 'owid_covid_compact.csv'
                                       AND rule_id <> 'DQ-03'
                                       AND load_timestamp >= @run_start);
    DECLARE @cases_pct      FLOAT = CAST(@cases_rejected AS FLOAT) / NULLIF(@cases_loaded + @cases_rejected, 0);

    IF @cases_pct > 0.05
    BEGIN
        SET @reject_threshold_fail = 1;
        SET @reject_threshold_notes = CONCAT(@reject_threshold_notes,
            'fact_covid_cases: ', FORMAT(@cases_pct * 100, 'N1'), '% rejected (threshold 5%). ');
    END;

    -- fact_vaccination (vaccinations_global.csv) — 10% threshold
    DECLARE @vacc_loaded    INT   = (SELECT COUNT(*) FROM dbo.fact_vaccination);
    DECLARE @vacc_rejected  INT   = (SELECT COUNT(*) FROM dbo.dq_rejected_rows
                                     WHERE source_file = 'vaccinations_global.csv'
                                       AND load_timestamp >= @run_start);
    DECLARE @vacc_pct       FLOAT = CAST(@vacc_rejected AS FLOAT) / NULLIF(@vacc_loaded + @vacc_rejected, 0);

    IF @vacc_pct > 0.10
    BEGIN
        SET @reject_threshold_fail = 1;
        SET @reject_threshold_notes = CONCAT(@reject_threshold_notes,
            'fact_vaccination: ', FORMAT(@vacc_pct * 100, 'N1'), '% rejected (threshold 10%). ');
    END;

    -- fact_hospitalization (hospital.csv) — 5% threshold
    DECLARE @hosp_loaded    INT   = (SELECT COUNT(*) FROM dbo.fact_hospitalization);
    DECLARE @hosp_rejected  INT   = (SELECT COUNT(*) FROM dbo.dq_rejected_rows
                                     WHERE source_file = 'hospital.csv'
                                       AND load_timestamp >= @run_start);
    DECLARE @hosp_pct       FLOAT = CAST(@hosp_rejected AS FLOAT) / NULLIF(@hosp_loaded + @hosp_rejected, 0);

    IF @hosp_pct > 0.05
    BEGIN
        SET @reject_threshold_fail = 1;
        SET @reject_threshold_notes = CONCAT(@reject_threshold_notes,
            'fact_hospitalization: ', FORMAT(@hosp_pct * 100, 'N1'), '% rejected (threshold 5%). ');
    END;

    IF LEN(@reject_threshold_notes) = 0
        SET @reject_threshold_notes = CONCAT(
            'fact_covid_cases=', FORMAT(ISNULL(@cases_pct,0)*100,'N1'), '% | ',
            'fact_vaccination=', FORMAT(ISNULL(@vacc_pct,0)*100,'N1'),  '% | ',
            'fact_hospitalization=', FORMAT(ISNULL(@hosp_pct,0)*100,'N1'), '%'
        );

    INSERT INTO #results VALUES (
        10, 'Rejection Threshold Check',
        CASE WHEN @reject_threshold_fail = 1 THEN 'FAIL' ELSE 'PASS' END,
        @cases_rejected + @vacc_rejected + @hosp_rejected,
        @reject_threshold_notes
    );

    -- --------------------------------------------------------
    -- CHECK 11 — Soft Outlier Detection (informational)
    -- Flags statistically unusual values for human review.
    -- Does not fail the package — OWID backlog corrections can
    -- produce legitimate single-day spikes.
    -- --------------------------------------------------------
    DECLARE @ol_notes NVARCHAR(500) = '';
    DECLARE @ol_count INT = 0;

    -- OL-01: single-day case spike > 1,000,000
    DECLARE @spike_count INT = (
        SELECT COUNT(*) FROM dbo.fact_covid_cases WHERE new_cases > 1000000
    );
    IF @spike_count > 0
    BEGIN
        SET @ol_count += @spike_count;
        SET @ol_notes = CONCAT(@ol_notes, 'OL-01: ', @spike_count, ' country-days with new_cases > 1M. ');
    END;

    -- OL-02: reproduction rate > 15
    DECLARE @rt_count INT = (
        SELECT COUNT(*) FROM dbo.fact_covid_cases WHERE reproduction_rate > 15
    );
    IF @rt_count > 0
    BEGIN
        SET @ol_count += @rt_count;
        SET @ol_notes = CONCAT(@ol_notes, 'OL-02: ', @rt_count, ' rows with reproduction_rate > 15. ');
    END;

    -- OL-03: logical inconsistency — people_vaccinated < people_fully_vaccinated
    DECLARE @vacc_logic_count INT = (
        SELECT COUNT(*) FROM dbo.fact_vaccination
        WHERE people_vaccinated IS NOT NULL
          AND people_fully_vaccinated IS NOT NULL
          AND people_vaccinated < people_fully_vaccinated
    );
    IF @vacc_logic_count > 0
    BEGIN
        SET @ol_count += @vacc_logic_count;
        SET @ol_notes = CONCAT(@ol_notes, 'OL-03: ', @vacc_logic_count, ' rows where fully_vaccinated > vaccinated. ');
    END;

    -- OL-04: new_cases > population (joined via dim_location)
    DECLARE @pop_exceed_count INT = (
        SELECT COUNT(*)
        FROM dbo.fact_covid_cases f
        JOIN dbo.dim_location l ON l.location_id = f.location_id
        WHERE f.new_cases IS NOT NULL
          AND l.population IS NOT NULL
          AND f.new_cases > l.population
    );
    IF @pop_exceed_count > 0
    BEGIN
        SET @ol_count += @pop_exceed_count;
        SET @ol_notes = CONCAT(@ol_notes, 'OL-04: ', @pop_exceed_count, ' rows where new_cases > country population. ');
    END;

    IF LEN(@ol_notes) = 0 SET @ol_notes = 'No outliers detected.';

    INSERT INTO #results VALUES (
        11, 'Soft Outlier Detection',
        'PASS',  -- never fails the package — informational only
        @ol_count,
        @ol_notes
    );

    -- --------------------------------------------------------
    -- Log all results to persistent history table
    -- --------------------------------------------------------
    INSERT INTO etl_verification_log (check_id, check_name, status, failure_count, notes)
    SELECT check_id, check_name, status, failure_count, notes FROM #results;

    -- --------------------------------------------------------
    -- Output summary result set
    -- --------------------------------------------------------
    SELECT
        check_id                                    AS [#],
        check_name                                  AS [Check],
        status                                      AS [Status],
        failure_count                               AS [Failures],
        ISNULL(notes, '')                           AS [Notes],
        GETDATE()                                   AS [Run Time]
    FROM #results
    ORDER BY check_id;

    -- --------------------------------------------------------
    -- Raise error if any critical check failed
    -- SSIS Execute SQL Task will catch this and fail the package
    -- Critical checks: 2, 3, 4, 7, 8, 10 (data integrity issues)
    -- --------------------------------------------------------
    IF EXISTS (
        SELECT 1 FROM #results
        WHERE status = 'FAIL'
          AND check_id IN (2, 3, 4, 7, 8, 10)
    )
    BEGIN
        DECLARE @failed_checks NVARCHAR(500);
        SELECT @failed_checks = STRING_AGG(check_name, ', ')
        FROM #results
        WHERE status = 'FAIL' AND check_id IN (2, 3, 4, 7, 8, 10);

        RAISERROR('ETL verification FAILED. Critical checks failed: %s', 16, 1, @failed_checks);
    END;

    DROP TABLE #results;
END;
GO
