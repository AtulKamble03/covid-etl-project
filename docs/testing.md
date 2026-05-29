# ETL Testing and Verification Strategy

After every SSIS package run, the stored procedure `usp_verify_etl_load` runs automatically as the final step. It executes 11 checks, logs results to `etl_verification_log`, and raises an error if any critical check fails — causing SSIS to mark the package as Failed.

> Stored procedure: [sql/usp_verify_etl_load.sql](../sql/usp_verify_etl_load.sql)
> Manual queries: [sql/verification_queries.sql](../sql/verification_queries.sql)

---

## How to Run

**One-time setup — run once in SSMS before first package execution:**
```sql
-- Creates etl_verification_log table + stored procedure
-- Open sql/usp_verify_etl_load.sql in SSMS and press F5
EXEC usp_verify_etl_load;
```

**After every SSIS run — SSIS calls this automatically as its last step:**
```sql
EXEC usp_verify_etl_load;
```

**To review verification history across all runs:**
```sql
SELECT * FROM etl_verification_log ORDER BY run_timestamp DESC;
```

---

## How SSIS Uses the Stored Procedure

Add an **Execute SQL Task** as the final step (Step 6) in the SSIS Control Flow:
- Connection: your SQL Server connection
- SQL Statement: `EXEC usp_verify_etl_load;`
- On failure (RAISERROR): SSIS marks the package as **Failed** — alerts you immediately

**Critical checks — trigger RAISERROR and fail the package: 2, 3, 4, 7, 8, 10**

**Informational checks — logged but do not fail the package: 1, 5, 6, 9, 11**

---

## When to Run Verification

| Trigger | Action |
|---|---|
| After every full SSIS package run | All 11 checks run automatically |
| After re-loading a single fact table | Run checks relevant to that table (2, 3, 4, 7, 10) |
| Before starting Phase 4 analytics | All 11 checks must show no critical failures |
| After migrating to Snowflake (Phase 5) | Re-run all 11 checks against Snowflake |

---

## Verification Checks

### Check 1 — Row Count Reconciliation (Informational)
**What:** Reports how many rows are in each table after load — dim_location, dim_date, and all three fact tables.

**Pass condition:** Always PASS — this is informational only. Used to compare run sizes over time (e.g., "did today's run load significantly fewer rows than yesterday?").

**Supplemented by:** `etl_run_log` table — captures rows extracted / loaded / rejected per Data Flow per run for more precise tracking.

---

### Check 2 — Null Foreign Key Check (Critical)
**What:** Confirm every row in every fact table has a valid `location_id` and `date_id` — no nulls.

**Pass condition:** 0 rows with null FKs.

**Failure means:** SSIS Lookup transformation failed to resolve a country name or date. Check the Lookup no-match output configuration.

---

### Check 3 — Duplicate Key Check (Critical)
**What:** Confirm no `(location_id, date_id)` combination appears more than once in each fact table.

**Pass condition:** 0 duplicate combinations.

**Failure means:** Package ran twice without truncating first, OR the SSIS Sort deduplication step (Step 1 of each fact flow) was misconfigured and let duplicate rows through.

---

### Check 4 — Referential Integrity Check (Critical)
**What:** Confirm every `location_id` in fact tables exists in `dim_location`, and every `date_id` exists in `dim_date`.

**Pass condition:** 0 orphan FK references.

**Failure means:** Dimensions were not loaded before facts, or a surrogate key mismatch occurred. Confirm Control Flow order — dims always load before facts.

---

### Check 5 — Aggregate Reconciliation (Informational)
**What:** Reports SUM of key metrics (`new_cases`, `new_deaths`) and MAX of cumulative metrics. Used as a sanity check to spot dramatic value shifts between runs.

**Pass condition:** Always PASS — informational only. Compare against previous runs to detect unexpected changes.

---

### Check 6 — DQ Reject Audit (Informational)
**What:** Reports the total number of rows rejected in the current run across all source files and all rule IDs.

**Pass condition:** Always PASS — informational only. The rejection threshold (Check 10) is the enforced check. This gives raw counts for investigation.

**How to drill into rejections:**
```sql
SELECT rule_id, source_file, COUNT(*) AS rejected_count
FROM dbo.dq_rejected_rows
WHERE load_timestamp >= CAST(GETDATE() AS DATE)
GROUP BY rule_id, source_file
ORDER BY rejected_count DESC;
```

---

### Check 7 — Negative Value Check (Critical)
**What:** Confirm no negative `new_cases`, `new_deaths`, `daily_vaccinations_smoothed`, or occupancy values exist in the fact tables after load.

**Pass condition:** 0 rows with negative values.

**Failure means:** DQ rules DQ-04 / DQ-05 did not fire correctly in SSIS — investigate Conditional Split configuration.

---

### Check 8 — Date Coverage Check (Critical)
**What:** Confirm `dim_date` has no gaps between 2020-01-01 and today.

**Pass condition:** Every date from 2020-01-01 to `GETDATE()` exists in `dim_date` with no missing days.

**Failure means:** dim_date Script Task missed a range — re-run the Script Task or check `MAXRECURSION` setting.

---

### Check 9 — Monotonic Totals Check (Informational)
**What:** Confirm `total_cases` and `total_deaths` never decrease day over day for any country.

**Pass condition:** Always PASS — informational only (OWID sometimes revises historical data downward, which is valid).

**Failure means:** Source data has a historical correction. Log as a known anomaly and document the date and country affected. This is expected behaviour when OWID publishes backlog corrections.

---

### Check 10 — Rejection Threshold Check (Critical)
**What:** Confirms that unexpected rejections do not exceed the acceptable percentage for each source file. DQ-03 rejects (aggregate row removal — "World", "Africa" etc.) are excluded from the calculation since they are expected.

| Source File | Fact Table | Threshold |
|---|---|---|
| `owid_covid_compact.csv` | `fact_covid_cases` | > 5% unexpected rejects → FAIL |
| `vaccinations_global.csv` | `fact_vaccination` | > 10% unexpected rejects → FAIL |
| `hospital.csv` | `fact_hospitalization` | > 5% unexpected rejects → FAIL |

**Pass condition:** Unexpected reject % is within threshold for all three sources.

**Failure means:** Either the source data quality has degraded significantly, or a DQ rule has become too aggressive. Check `dq_rejected_rows` filtered by today's date to identify the dominant rule_id.

**On failure:** The warehouse is left in a truncated/partial state. Do not use data for reporting until the issue is resolved and the package re-runs successfully.

---

### Check 11 — Soft Outlier Detection (Informational)
**What:** Flags statistically unusual values for human review. Does not fail the package — these may be valid (e.g., OWID publishing a historical backlog correction as a single large spike).

| Rule | Check | Typical cause |
|---|---|---|
| OL-01 | `new_cases > 1,000,000` for any country-day | Backlog correction dump — review and confirm |
| OL-02 | `reproduction_rate > 15` | No epidemiological precedent — likely data error |
| OL-03 | `people_vaccinated < people_fully_vaccinated` | Logical impossibility — source data issue |
| OL-04 | `new_cases > population` for the country | Physically impossible — data error |

**Pass condition:** Always PASS — informational only.

**Action:** Review the notes column in `etl_verification_log` for the count and type of anomalies. Investigate if the count is unexpectedly high.

---

## Pass / Fail Summary Template

Record results after every load. Critical checks must all PASS before proceeding to analytics.

| # | Check | Type | Result | Rows Flagged | Notes |
|---|---|---|---|---|---|
| 1 | Row count reconciliation | Informational | PASS / FAIL | | |
| 2 | Null FK check | **Critical** | PASS / FAIL | | |
| 3 | Duplicate key check | **Critical** | PASS / FAIL | | |
| 4 | Referential integrity | **Critical** | PASS / FAIL | | |
| 5 | Aggregate reconciliation | Informational | PASS / FAIL | | |
| 6 | DQ reject audit | Informational | PASS / FAIL | | |
| 7 | Negative value check | **Critical** | PASS / FAIL | | |
| 8 | Date coverage check | **Critical** | PASS / FAIL | | |
| 9 | Monotonic totals check | Informational | PASS / FAIL | | |
| 10 | Rejection threshold check | **Critical** | PASS / FAIL | | |
| 11 | Soft outlier detection | Informational | PASS / FAIL | | |

**All 6 critical checks (2, 3, 4, 7, 8, 10) must PASS before proceeding to Phase 4 analytics.**
