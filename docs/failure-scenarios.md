# ETL Failure Scenarios — Test Guide

Use these scenarios to verify the pipeline fails correctly, logs the failure, and the verification SP catches it.

Run each test in SSMS, then re-run the SSIS package, then check `EXEC usp_verify_etl_load` to see which check caught it.

---

## How to Test

1. Run the SQL in the "Setup" column in SSMS
2. Run the SSIS package (F5 in Visual Studio or via SQL Server Agent)
3. Run `EXEC usp_verify_etl_load` — check which check FAILS
4. Run the "Cleanup" SQL to restore the original state

---

## Scenario 1 — Null Foreign Key (CHECK 2)

**What it tests:** A fact row with no location_id or date_id — orphan row.

**Setup:**
```sql
USE covid_dw;
-- Insert a fact row with NULL location_id — bypasses SSIS lookup
SET IDENTITY_INSERT dbo.fact_covid_cases ON;
INSERT INTO dbo.fact_covid_cases (case_id, record_year, location_id, date_id, new_cases)
VALUES (9999999, 2022, NULL, 1, 100);
SET IDENTITY_INSERT dbo.fact_covid_cases OFF;
```

**Expected:** CHECK 2 (Null Foreign Key) → **FAIL**

**Cleanup:**
```sql
DELETE FROM dbo.fact_covid_cases WHERE case_id = 9999999;
```

---

## Scenario 2 — Duplicate Key (CHECK 3)

**What it tests:** Two rows for the same country on the same day.

**Setup:**
```sql
USE covid_dw;
-- Get an existing location_id and date_id
DECLARE @loc INT = (SELECT TOP 1 location_id FROM dbo.dim_location WHERE country = 'Afghanistan');
DECLARE @dt  INT = (SELECT TOP 1 date_id FROM dbo.dim_date WHERE date = '2022-01-01');

-- Drop UNIQUE constraint temporarily to allow duplicate insert
ALTER TABLE dbo.fact_covid_cases DROP CONSTRAINT uq_covid_cases_location_date;

-- Insert duplicate row
INSERT INTO dbo.fact_covid_cases (record_year, location_id, date_id, new_cases)
VALUES (2022, @loc, @dt, 99999);
```

**Expected:** CHECK 3 (Duplicate Key) → **FAIL**

**Cleanup:**
```sql
-- Remove the duplicate (keep the original)
WITH cte AS (
    SELECT *, ROW_NUMBER() OVER (PARTITION BY location_id, date_id ORDER BY case_id) AS rn
    FROM dbo.fact_covid_cases
    WHERE location_id = (SELECT location_id FROM dbo.dim_location WHERE country = 'Afghanistan')
      AND date_id = (SELECT date_id FROM dbo.dim_date WHERE date = '2022-01-01')
)
DELETE FROM cte WHERE rn > 1;

-- Restore constraint
ALTER TABLE dbo.fact_covid_cases
ADD CONSTRAINT uq_covid_cases_location_date UNIQUE NONCLUSTERED (location_id, date_id, record_year);
```

---

## Scenario 3 — Negative Value (CHECK 7)

**What it tests:** A negative new_cases value slipping past DQ rules.

**Setup:**
```sql
USE covid_dw;
-- Update an existing row to have negative cases
UPDATE TOP(1) dbo.fact_covid_cases
SET new_cases = -500
WHERE new_cases IS NOT NULL AND new_cases > 0;
```

**Expected:** CHECK 7 (Negative Value Check) → **FAIL**

**Cleanup:**
```sql
-- Re-run the SSIS package (it will reload all data fresh)
-- OR manually restore:
UPDATE dbo.fact_covid_cases SET new_cases = 500
WHERE new_cases = -500;
```

---

## Scenario 4 — Date Gap in dim_date (CHECK 8)

**What it tests:** A missing date in the calendar dimension.

**Setup:**
```sql
USE covid_dw;
-- Delete a date from dim_date — this should be blocked by FK
-- First delete the fact rows for that date
DECLARE @gap_date_id INT = (SELECT date_id FROM dbo.dim_date WHERE date = '2022-06-15');

DELETE FROM dbo.fact_covid_cases    WHERE date_id = @gap_date_id;
DELETE FROM dbo.fact_vaccination    WHERE date_id = @gap_date_id;
DELETE FROM dbo.fact_hospitalization WHERE date_id = @gap_date_id;
DELETE FROM dbo.dim_date            WHERE date_id = @gap_date_id;
```

**Expected:** CHECK 8 (Date Coverage) → **FAIL** with "1 missing dates in dim_date"

**Cleanup:**
```sql
-- Re-run the SSIS package — dim_date is fully regenerated every run
```

---

## Scenario 5 — Rejection Threshold Exceeded (CHECK 10)

**What it tests:** What happens when too many rows are in dq_rejected_rows.

**Setup:**
```sql
USE covid_dw;
-- Simulate a high rejection count by inserting fake reject rows
INSERT INTO dbo.dq_rejected_rows (source_file, rule_id, reject_reason, raw_country, raw_date, load_timestamp)
SELECT TOP 50000
    'owid_covid_compact.csv',
    'DQ-01',
    'Simulated high rejection for threshold test',
    'TestCountry',
    '2022-01-01',
    GETDATE()
FROM sys.all_columns;
```

**Expected:** CHECK 10 (Rejection Threshold) → **FAIL** — fact_covid_cases reject % > 5%

**Cleanup:**
```sql
DELETE FROM dbo.dq_rejected_rows
WHERE reject_reason = 'Simulated high rejection for threshold test';
```

---

## Scenario 6 — Referential Integrity Break (CHECK 4)

**What it tests:** A fact row pointing to a location_id that no longer exists in dim_location.

**Setup:**
```sql
USE covid_dw;
-- Get a location_id that has fact rows
DECLARE @loc INT = (SELECT TOP 1 location_id FROM dbo.dim_location WHERE country = 'Chad');

-- Drop FK constraint temporarily
ALTER TABLE dbo.fact_covid_cases DROP CONSTRAINT fk_covid_cases_loc;

-- Delete the dim row (without cascading)
DELETE FROM dbo.dim_location WHERE location_id = @loc;
```

**Expected:** CHECK 4 (Referential Integrity) → **FAIL**

**Cleanup:**
```sql
-- Re-run SSIS package — dim_location is fully reloaded every run
-- Also restore FK:
ALTER TABLE dbo.fact_covid_cases
ADD CONSTRAINT fk_covid_cases_loc FOREIGN KEY (location_id) REFERENCES dbo.dim_location(location_id);
```

---

## Scenario 7 — Package Truncate Fails (FK Order Wrong)

**What it tests:** What happens if you run the package without truncating facts first.

**Setup:**
```sql
USE covid_dw;
-- Simulate: comment out "Truncate All Facts" by running ONLY the dim delete
-- (Do this from SSMS, not SSIS)
DELETE FROM dbo.dim_date;   -- This should FAIL with FK constraint error
```

**Expected:** SQL error: "DELETE statement conflicted with REFERENCE constraint"
The SSIS package would also fail at "Truncate dim_date" step if "Truncate All Facts" doesn't run first.

**Cleanup:** No cleanup needed — DELETE failed, no data was changed.

---

## Quick Verification After Each Test

```sql
-- Run this after each scenario to see which check fails
EXEC dbo.usp_verify_etl_load;

-- Also check what's in the reject table
SELECT rule_id, source_file, COUNT(*) AS cnt
FROM dbo.dq_rejected_rows
WHERE CAST(load_timestamp AS DATE) = CAST(GETDATE() AS DATE)
GROUP BY rule_id, source_file
ORDER BY cnt DESC;

-- Check verification history
SELECT TOP 20 *
FROM dbo.etl_verification_log
ORDER BY run_timestamp DESC, check_id;
```

---

## Reset Everything to Clean State

```sql
-- After all testing, run the SSIS package once to reload clean data
-- In Visual Studio: F5
-- In SQL Server Agent: right-click job → Start Job at Step
```
