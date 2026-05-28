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
    DECLARE @rejected_rows INT = (
        SELECT COUNT(*) FROM dq_rejected_rows
        WHERE load_timestamp >= CAST(GETDATE() AS DATE)
    );

    SET @notes = CONCAT('Rows rejected in this run: ', @rejected_rows,
        CASE WHEN @rejected_rows > 1000 THEN ' — HIGH rejection count, investigate source data' ELSE '' END
    );

    INSERT INTO #results VALUES (
        6, 'DQ Reject Audit',
        CASE WHEN @rejected_rows > 1000 THEN 'FAIL' ELSE 'PASS' END,
        @rejected_rows,
        @notes
    );

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
    SET @failures = (
        WITH date_series AS (
            SELECT CAST('2020-01-01' AS DATE) AS expected_date
            UNION ALL
            SELECT DATEADD(DAY, 1, expected_date)
            FROM date_series
            WHERE expected_date < CAST(GETDATE() AS DATE)
        )
        SELECT COUNT(*) FROM date_series ds
        WHERE NOT EXISTS (SELECT 1 FROM dim_date d WHERE d.date = ds.expected_date)
        OPTION (MAXRECURSION 3000)
    );

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
    -- Critical checks: 2, 3, 4, 7, 8 (data integrity issues)
    -- --------------------------------------------------------
    IF EXISTS (
        SELECT 1 FROM #results
        WHERE status = 'FAIL'
          AND check_id IN (2, 3, 4, 7, 8)
    )
    BEGIN
        DECLARE @failed_checks NVARCHAR(500);
        SELECT @failed_checks = STRING_AGG(check_name, ', ')
        FROM #results
        WHERE status = 'FAIL' AND check_id IN (2, 3, 4, 7, 8);

        RAISERROR('ETL verification FAILED. Critical checks failed: %s', 16, 1, @failed_checks);
    END;

    DROP TABLE #results;
END;
GO
