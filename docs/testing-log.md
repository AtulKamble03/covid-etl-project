# ETL Build — Testing Log, Issues Encountered & Resolutions

This document captures every error encountered during the SSIS package build,
the root cause, the fix applied, and the lesson learned. Also includes the
designed failure scenarios for ongoing verification testing.

> **Note on screenshots:** Screenshots were captured during live testing sessions.
> Results are documented in text form below since screenshots cannot be stored
> as files in this repo. All test results are reproducible by running the SQL
> provided in PART 2.

---

## PART 0 — Verification SP Baseline Results (Clean Run)

**Date:** 2026-06-02 | **Run by:** Atul Kamble | **Environment:** PG04CRRX / covid_dw

**Executive Summary (clean run — all data freshly loaded):**

| Field | Value |
|---|---|
| Overall Status | **PASS** |
| Critical Failures | 0 |
| fact_covid_cases rows | 484,751 |
| fact_vaccination rows | 197,657 |
| fact_hospitalization rows | 41,543 |
| dim_location countries | 248 |
| dim_date days | 2,345 (2020-01-01 to 2026-06-02) |

**Full check results (clean run):**

| # | Check | Status | Count | Key Note |
|---|---|---|---|---|
| 1 | Load Summary | PASS | 0 | dim_location=248 \| dim_date=2345 days |
| 2 | Null Foreign Key Check | PASS | 0 | All FK columns populated |
| 3 | Duplicate Key Check | PASS | 0 | No duplicates |
| 4 | Referential Integrity | PASS | 0 | All FK references valid |
| 5 | Aggregate Sanity | PASS | 0 | SUM(new_cases)=2,225,774,937 |
| 6 | DQ Reject Audit | PASS | 0 | Total rejected rows: 0 |
| 7 | Negative Value Check | PASS | 0 | No negative values |
| 8 | Date Coverage Check | PASS | 0 | 2020-01-01 to 2026-06-02 — no gaps |
| 9 | Monotonic Totals Check | WARN | 77 | 77 OWID historical corrections (expected) |
| 10 | Rejection Threshold | PASS | 0 | fact_covid_cases=0.0% \| vacc=0.0% \| hosp=0.0% |
| 11 | Soft Outlier Detection | PASS | 820 | OL-01: 301 days new_cases>1M \| OL-03: 519 rows |
| 12 | Partition Health | PASS | 0 | P1=65,554 \| P2=51,421 \| P3=70,044 \| P4=89,144 \| P5=88,798 \| P6=88,330 \| P7=31,460 |

---

## PART 0b — Failure Test Results

### Test 1 — Null FK (modified to Referential Integrity test)
**Date:** 2026-06-02

**Note:** Original Test 1 (NULL location_id) was blocked by the database NOT NULL constraint.
This confirmed the DB constraint is working correctly as Layer 1 defence.

**Modified test:** Inserted row with invalid location_id=99999 (bypassing FK via NOCHECK CONSTRAINT)

**Result:**
| Field | Value |
|---|---|
| Overall Status | **FAIL** |
| Critical Failures | 1 |
| fact_covid_cases rows | 484,752 (1 extra bad row) |
| CHECK 4 — Referential Integrity | **FAIL**, Count: 1 |
| Notes | "Orphan FK rows found — dims may have reloaded with new identity values" |
| All other critical checks | PASS |

**Outcome:** ✅ Verification correctly detected the orphan FK row and marked package FAIL.
**Cleanup:** Re-run pipeline — TRUNCATE removed the bad row automatically.

---

### Test 2 — Duplicate Key (CHECK 3)
**Date:** 2026-06-02

**Setup:** Dropped UNIQUE constraint on (location_id, date_id, record_year), inserted
duplicate row for Afghanistan 2022-01-01.

**Result:**
| Field | Value |
|---|---|
| Overall Status | **FAIL** |
| Critical Failures | 1 |
| fact_covid_cases rows | 484,752 (1 extra duplicate row) |
| CHECK 3 — Duplicate Key Check | **FAIL**, Count: 1 |
| Notes | "Duplicate (location_id, date_id) combinations found" |
| All other critical checks | PASS |

**SSIS behaviour:** Post-Load Verification task showed **red X** in Control Flow —
RAISERROR fired and SSIS marked the task as Failed. In a scheduled job, SQL Server
Agent would log this as a job failure, visible in job history.

**Outcome:** ✅ Verification correctly detected the duplicate and failed the pipeline.
**Cleanup required:** Restore UNIQUE constraint manually, then re-run pipeline.

---

### Test 3 — Negative Value (CHECK 7)
**Date:** 2026-06-02

**Setup:** Updated one row in fact_covid_cases to new_cases = -500 (simulating DQ-04 bypass).

**Result:**
| Field | Value |
|---|---|
| Overall Status | **FAIL** |
| Critical Failures | 1 |
| fact_covid_cases rows | 484,751 (same — UPDATE not INSERT) |
| CHECK 7 — Negative Value Check | **FAIL**, Count: 1 |
| Notes | "Negative metric values found — DQ-04/DQ-05 Conditional Split may not have fired" |
| All other critical checks | PASS |

**Outcome:** ✅ Verification correctly detected the negative value.
**Cleanup:** Pipeline TRUNCATE auto-resolved — no manual step needed.

---

### Test 4 — Date Gap in dim_date (CHECK 8)
**Date:** 2026-06-02

**Setup:** Deleted all fact rows for 2022-06-15, then deleted that date from dim_date.

**Result:**
| Field | Value |
|---|---|
| Overall Status | **FAIL** |
| Critical Failures | 1 |
| fact_covid_cases rows | 484,599 (152 rows removed for that date) |
| fact_vaccination rows | 197,440 (217 rows removed) |
| fact_hospitalization rows | 41,509 (34 rows removed) |
| dim_date days | 2,344 (was 2,345 — 1 missing) |
| CHECK 8 — Date Coverage Check | **FAIL**, Count: 1 |
| Notes | "1 missing dates in dim_date — Script Task may have used wrong start date or IDENTITY not reseeded" |
| All other critical checks | PASS |

**Additional observation:** CHECK 1 (Load Summary) also surfaced the row count drops across all
3 fact tables — providing an early signal even before CHECK 8 fires.

**Outcome:** ✅ Verification correctly detected the date gap and surfaced fact row count drops.
**Cleanup:** Pipeline auto-resolved — dim_date fully regenerated, facts reloaded.

---

## PART 1 — Build Issues Encountered and Fixed

---

### Issue 1 — CTE Syntax Error in usp_verify_etl_load
**Error:** `Incorrect syntax near the keyword 'WITH'`
**Where:** `sql/usp_verify_etl_load.sql` CHECK 8 (Date Coverage)
**Root Cause:** SQL Server does not allow a `WITH` (CTE) clause inside
`SET @var = (subquery)`. A CTE must stand alone as its own statement.
**Fix:** Restructured to `SELECT @var = COUNT(*) FROM cte WHERE...`
instead of `SET @var = (WITH cte AS (...) SELECT COUNT(*) ...)`
**Lesson:** When using CTEs inside stored procedures, always use
`SELECT @var = ...` not `SET @var = (...)` to assign results.

---

### Issue 2 — OLE DB Provider Not Installed (SQLNCLI11)
**Error:** `The 'SQLNCLI11' provider is not registered on the local machine`
**Where:** SSIS OLE DB Connection Manager
**Root Cause:** SQLNCLI11 (SQL Server Native Client 11) was deprecated in 2022
and not installed on the machine.
**Fix:** Changed provider to `Microsoft OLE DB Driver for SQL Server` (MSOLEDBSQL)
**Lesson:** Always use MSOLEDBSQL for modern SQL Server connections. SQLNCLI11
is deprecated. Production ETL server build checklists should include MSOLEDBSQL.

---

### Issue 3 — TRUNCATE Blocked by FK Constraints (dim tables)
**Error:** `Cannot truncate table 'dbo.dim_date' because it is being referenced by a FOREIGN KEY constraint`
**Where:** `Truncate dim_date` Execute SQL Task
**Root Cause:** TRUNCATE cannot be used on a table that other tables reference
via FK, even when those referencing tables are empty.
**Fix:** Changed from `TRUNCATE TABLE dbo.dim_date` to `DELETE FROM dbo.dim_date`
**Lesson:** TRUNCATE checks FK references. DELETE does not. For parent tables in
a star schema (dims), always use DELETE. For child tables (facts), TRUNCATE works.

---

### Issue 4 — DBCC CHECKIDENT Not Resetting dim_date Identity
**Error:** `fact_vaccination FK violation on date_id` — date_ids were 42193+ instead of 1
**Where:** dim_date Script Task identity management
**Root Cause:** DBCC CHECKIDENT was not reliably resetting the identity counter after
DELETE. After ~18 package runs, the counter had accumulated to 42193. The DATEDIFF
formula (`DATEDIFF("day","2020-01-01",date) + 1`) assumes date_id=1 for 2020-01-01.
**Fix:** Changed Script Task to use `SET IDENTITY_INSERT dbo.dim_date ON` and insert
explicit `date_id` values (1, 2, 3...) in the C# loop. Guaranteed every run starts at 1.
**Lesson:** Never rely on DBCC CHECKIDENT for identity reseeding in automated pipelines.
Always use IDENTITY INSERT with explicit values when you need predictable identity sequences.

---

### Issue 5 — Text Qualifier Missing in Flat File Connection Manager
**Error:** `Data conversion failed` on `date` column at row 580,496
**Where:** `Load fact_covid_cases` Data Flow, Flat File Source
**Root Cause:** The compact CSV contains country names with commas
(e.g., "World excl. China, South Korea, Japan and Singapore"). Without a
text qualifier, SSIS split on those commas, shifting all columns for those rows.
The `date` column received " South Korea" instead of "2020-01-05".
**Fix:** Set Text Qualifier to `"` (double quote) in FF_CompactCSV
**Lesson:** Always set a text qualifier when loading CSVs that contain text fields
(names, descriptions). Free-text fields almost always contain the delimiter character.

---

### Issue 6 — Wrong Date Column Type in FF_Vaccinations (DT_DBTIME vs DT_DBDATE)
**Error:** `The data types 'DT_DBTIME' and 'DT_DBDATE' are incompatible`
**Where:** `Load fact_vaccination` Conditional Split
**Root Cause:** The `date` column in FF_Vaccinations was accidentally set to
`DT_DBTIME` (time-only) instead of `DT_DBDATE` (date-only) when configuring
the Advanced settings.
**Fix:** Changed `date` column DataType to `database date [DT_DBDATE]`
**Lesson:** DT_DBTIME = time only, DT_DBDATE = date only. Easy to confuse
in the dropdown. Always double-check the selected type when configuring date columns.

---

### Issue 7 — VS 2022 Lookup "Create Relationships" Dialog Bug
**Error:** Lookup Column dropdown always empty — could not set up date_id Lookup
**Where:** `Load fact_vaccination` and `Load fact_hospitalization` date_id Lookup
**Root Cause:** Visual Studio 2022 SSIS Lookup component's "Create Relationships"
dialog does not populate the reference column dropdown, regardless of table or
SQL query mode. This is a known VS 2022 SSIS bug.
**Fix (date_id):** Eliminated the Lookup entirely. Used a Derived Column with:
`DATEDIFF("day",(DT_DBTIMESTAMP)"2020-01-01",(DT_DBTIMESTAMP)[date]) + 1`
This works because dim_date is always loaded with identity starting at 1 for 2020-01-01.
**Lesson:** When a tool has a known bug, find a mathematical workaround rather than
fighting the UI. The DATEDIFF formula is actually more reliable than a Lookup because
it has zero dependency on the Lookup component's metadata system.

---

### Issue 8 — Data Conversion Fails on Empty Strings
**Error:** `The value could not be converted because of a potential loss of data`
**Where:** Multiple fact/dim Data Flow Tasks, Data Conversion component
**Root Cause:** The CSV stores all values as strings. Empty fields are `""`
(empty string), not NULL. The Data Conversion component cannot convert `""` to
DT_R8 (float) — it treats it as a conversion failure.
**Fix:** Replaced Data Conversion with Derived Column using null-safe expressions:
`[col] == "" ? NULL(DT_R8) : (DT_R8)[col]`
This explicitly converts empty string to NULL before the type cast.
**Lesson:** Always use Derived Column with null-safe expressions when loading
numeric columns from CSV files. Data Conversion is not null-aware.

---

### Issue 9 — NULL Comparison Returns NULL in Conditional Split (not false)
**Error:** `The expression 'new_cases_conv < 0' evaluated to NULL`
**Where:** `Load fact_covid_cases` Conditional Split
**Root Cause:** In SSIS, `NULL < 0` evaluates to NULL (not false), and the
Conditional Split requires a Boolean result. Any nullable column comparison
without an ISNULL guard will fail at runtime when that column contains NULL.
**Fix:** Added `!ISNULL()` guard to all nullable column comparisons:
`!ISNULL([new_cases_conv]) && [new_cases_conv] < 0`
**Lesson:** In SSIS Conditional Split, ALWAYS wrap nullable column comparisons
with `!ISNULL([col]) &&` prefix. NULL comparisons do NOT return false — they
return NULL, which is an error.

---

### Issue 10 — OWI Duplicate Key from CHAR(3) Code Column Truncation
**Error:** `Violation of UNIQUE KEY constraint — duplicate key value is (OWI)`
**Where:** `Load dim_location` OLE DB Destination
**Root Cause:** OWID uses 8-character codes for some territories (OWID_KOS for
Kosovo, OWID_TRS for Transnistria). The `code` column was defined as CHAR(3).
Both codes truncated to "OWI" → duplicate key violation.
**Fix:** Changed `code` column from `CHAR(3)` to `VARCHAR(10)` in both
`create_tables.sql` and SQL Server (ALTER TABLE + drop/recreate UNIQUE constraint)
**Lesson:** Never assume ISO-3 codes are exactly 3 characters. OWID and other
publishers use non-standard codes for disputed territories. Use VARCHAR(10)
for any code column that might receive extended values.

---

### Issue 11 — SCD Type 1 Upsert Changed to DELETE + Full Reload
**Design change:** Original LLD specified SCD Type 1 upsert for dim_location
(IF NOT EXISTS insert). During implementation this was changed to DELETE + full reload.
**Reason:** The upsert approach was more complex, required tracking existing codes,
and provided no benefit since the full CSV is always available. DELETE + reload
is simpler, idempotent, and guarantees the warehouse matches the current source.
**Lesson:** For full-extract pipelines where the complete source is always
available, DELETE + full reload is usually simpler and safer than upsert.
Reserve upsert for incremental/API sources where you don't have the full dataset.

---

### Issue 12 — SQL Server Agent Job Failing (Azure AD Owner)
**Error:** `Unable to determine if the owner (AzureAD\AtulKamble) of job has server access`
**Where:** SQL Server Agent job execution
**Root Cause:** SQL Server Agent cannot verify Azure AD accounts as job owners.
The job was created while logged in as an Azure AD user, making that account
the owner. Agent cannot resolve Azure AD accounts for ownership verification.
**Fix:** Changed job owner from `AzureAD\AtulKamble` to `sa` in job properties.
**Lesson:** Always set SQL Server Agent job owner to `sa` or a SQL Server login
(not an Azure AD or Windows domain account) to avoid identity resolution issues.

---

### Issue 13 — BimlExpress Not Available for Visual Studio 2022
**Attempted:** Install BimlExpress extension to generate SSIS packages from Biml code
**Result:** Extension not found in VS 2022 marketplace — Varigence discontinued
the free version for VS 2022.
**Workaround:** Built packages manually in VS 2022. Biml file written as a
reference artifact (`ssis/fact_vaccination.biml`) showing the code-based approach.
**Lesson:** Always verify tool compatibility before planning to use it. BimlExpress
works with VS 2019 and earlier. For VS 2022, consider BimlStudio (paid) or
manual package building.

---

### Issue 14 — fact_vaccination DT_R8 Metadata Not Propagating
**Error:** `Invalid character value for cast specification` on `roll_9m_conv`
**Where:** `Load fact_vaccination` OLE DB Destination
**Root Cause:** SSIS metadata caching — after changing FF_Vaccinations column types,
the OLE DB Destination retained stale `cachedDataType="str"` for all numeric `_conv`
columns. Changing the connection manager type does not automatically propagate to
downstream components in VS 2022.
**Fix:** Deleted the OLE DB Destination and added a fresh one. Fresh components
always read current metadata from the upstream pipeline.
**Lesson:** After changing column types in a Flat File Connection Manager, always
delete and re-add OLE DB Destination components. The metadata cache is not
automatically invalidated. This is a known SSIS VS 2022 behavior.

---

## PART 2 — Designed Failure Scenarios for Ongoing Testing

Run these in SSMS to verify the verification SP detects each failure correctly.
After each test, run: `EXEC dbo.usp_verify_etl_load;`
Then clean up by re-running the SSIS package (SQL Server Agent job).

---

### Test 1 — Null Foreign Key (triggers CHECK 2)
```sql
USE covid_dw;
SET IDENTITY_INSERT dbo.fact_covid_cases ON;
INSERT INTO dbo.fact_covid_cases (case_id, record_year, location_id, date_id, new_cases)
VALUES (9999999, 2022, NULL, 1, 100);
SET IDENTITY_INSERT dbo.fact_covid_cases OFF;
-- Expected: CHECK 2 FAIL — "Null Foreign Key Check"
-- Cleanup: Re-run SSIS package (TRUNCATE wipes the row)
```

---

### Test 2 — Duplicate Country+Date (triggers CHECK 3)
```sql
USE covid_dw;
DECLARE @loc INT = (SELECT TOP 1 location_id FROM dbo.dim_location WHERE country = 'Afghanistan');
DECLARE @dt  INT = (SELECT TOP 1 date_id FROM dbo.dim_date WHERE date = '2022-01-01');
ALTER TABLE dbo.fact_covid_cases DROP CONSTRAINT uq_covid_cases_loc_date;
INSERT INTO dbo.fact_covid_cases (record_year, location_id, date_id, new_cases)
VALUES (2022, @loc, @dt, 99999);
-- Expected: CHECK 3 FAIL — "Duplicate Key Check"
-- Cleanup: Re-run SSIS package + restore constraint
ALTER TABLE dbo.fact_covid_cases
ADD CONSTRAINT uq_covid_cases_loc_date UNIQUE NONCLUSTERED (location_id, date_id, record_year);
```

---

### Test 3 — Negative Value (triggers CHECK 7)
```sql
USE covid_dw;
UPDATE TOP(1) dbo.fact_covid_cases
SET new_cases = -500
WHERE new_cases IS NOT NULL AND new_cases > 0;
-- Expected: CHECK 7 FAIL — "Negative Value Check"
-- Cleanup: Re-run SSIS package
```

---

### Test 4 — Date Gap in dim_date (triggers CHECK 8)
```sql
USE covid_dw;
DECLARE @gap_id INT = (SELECT date_id FROM dbo.dim_date WHERE date = '2022-06-15');
DELETE FROM dbo.fact_covid_cases    WHERE date_id = @gap_id;
DELETE FROM dbo.fact_vaccination    WHERE date_id = @gap_id;
DELETE FROM dbo.fact_hospitalization WHERE date_id = @gap_id;
DELETE FROM dbo.dim_date            WHERE date_id = @gap_id;
-- Expected: CHECK 8 FAIL — "Date Coverage Check" — 1 missing date
-- Cleanup: Re-run SSIS package (dim_date fully regenerated)
```

---

### Test 5 — Rejection Threshold Exceeded (triggers CHECK 10)
```sql
USE covid_dw;
INSERT INTO dbo.dq_rejected_rows (source_file, rule_id, reject_reason, load_timestamp)
SELECT TOP 50000
    'owid_covid_compact.csv', 'DQ-01',
    'Simulated rejection for threshold test', GETDATE()
FROM sys.all_columns;
-- Expected: CHECK 10 FAIL — reject % > 5% threshold
-- Cleanup:
DELETE FROM dbo.dq_rejected_rows WHERE reject_reason = 'Simulated rejection for threshold test';
```

---

### Test 6 — Run Verification Manually After Real Pipeline Run
```sql
-- Best way to verify the SP works correctly after a real load
EXEC dbo.usp_verify_etl_load;
-- Review both result sets:
-- 1. Executive Summary (Overall Status, row counts, run date)
-- 2. Full check results (12 rows, type, status, count, notes)

-- Check history:
SELECT TOP 24 run_timestamp, check_id, check_name, status, failure_count, notes
FROM dbo.etl_verification_log
ORDER BY run_timestamp DESC, check_id;
```

---

### Test 7 — Individual Task Execution in Visual Studio
To test a specific SSIS task without running the full package:
1. Open Package.dtsx in Visual Studio
2. Right-click any Control Flow task → "Execute Task"
3. Only that task runs — useful for testing individual steps

To test Post-Load Verification in isolation:
1. Introduce a failure in SSMS (e.g., Test 3 above)
2. Right-click "Post-Load Verification" → "Execute Task"
3. Check the verification log in SSMS for the result

---

## PART 3 — Quick Reference: Check Numbers and What They Catch

| # | Type | Check | Catches |
|---|---|---|---|
| 1 | Info | Load Summary | Row counts + date ranges per table |
| 2 | Critical | Null FK Check | Rows with missing location_id or date_id |
| 3 | Critical | Duplicate Key | Same country+date loaded twice |
| 4 | Critical | Referential Integrity | FK pointing to non-existent dim row |
| 5 | Info | Aggregate Sanity | Total cases/deaths/vaccinations globally |
| 6 | Info | DQ Reject Audit | Total rows rejected this run |
| 7 | Critical | Negative Value | Negative case or death counts |
| 8 | Critical | Date Coverage | Missing dates in dim_date |
| 9 | Info | Monotonic Totals | Cumulative counts decreasing (OWID corrections) |
| 10 | Critical | Rejection Threshold | >5%/10% unexpected rejections per source |
| 11 | Info | Soft Outlier | New cases >1M, bad vaccination logic |
| 12 | Info | Partition Health | Row distribution across 7 year partitions |
