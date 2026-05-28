# ETL Testing and Verification Strategy

After every SSIS package run, execute `sql/verification_queries.sql` in SSMS to confirm the data loaded correctly. All checks should pass before moving to analytics.

> Physical queries: [sql/verification_queries.sql](../sql/verification_queries.sql)

---

## When to Run Verification

| Trigger | Action |
|---|---|
| After every full SSIS package run | Run all 9 checks |
| After re-loading a single fact table | Run checks relevant to that table |
| Before starting Phase 4 analytics | Run all 9 checks — data must be clean |
| After migrating to Snowflake (Phase 5) | Run all 9 checks against Snowflake |

---

## Verification Checks

### Check 1 — Row Count Reconciliation
**What:** Confirm the number of rows loaded to each fact table matches the number of valid source rows (after DQ filtering).

**Pass condition:** Target row count = source row count minus rejected rows.

**Failure means:** Rows were silently dropped during SSIS load — investigate the SSIS error output.

---

### Check 2 — Null Foreign Key Check
**What:** Confirm every row in every fact table has a valid `location_id` and `date_id` (no nulls).

**Pass condition:** 0 rows with null FKs.

**Failure means:** SSIS Lookup transformation failed to resolve a country name or date — that row was not matched to a dimension. Check the Lookup no-match output.

---

### Check 3 — Duplicate Key Check
**What:** Confirm no (location_id + date_id) combination appears more than once in each fact table.

**Pass condition:** 0 duplicate combinations.

**Failure means:** The SSIS package was run twice without truncating first, OR source data has duplicate rows that passed DQ rules.

---

### Check 4 — Referential Integrity Check
**What:** Confirm every location_id in fact tables exists in dim_location, and every date_id exists in dim_date.

**Pass condition:** 0 orphan FK references.

**Failure means:** Dimensions were not loaded before facts, or a surrogate key mismatch occurred.

---

### Check 5 — Aggregate Reconciliation
**What:** Compare SUM of key metrics between source CSV and warehouse fact table.

**Pass condition:** Totals match within an acceptable tolerance (0 for exact, or <0.01% for floating point).

**Failure means:** Transformation logic changed a value, or rows were dropped without being counted as rejected.

---

### Check 6 — DQ Reject Audit
**What:** Review the `dq_rejected_rows` table to understand how many rows were rejected and why.

**Pass condition:** Rejection count is within expected range. Any unexpected spike in rejections must be investigated before proceeding.

**Failure means:** A DQ rule is rejecting valid rows (rule too strict), or source data quality has degraded.

---

### Check 7 — Negative Value Check
**What:** Confirm no negative new_cases or new_deaths exist in fact_covid_cases after load.

**Pass condition:** 0 rows with negative values.

**Failure means:** DQ rule DQ-04 / DQ-05 did not fire correctly in SSIS — investigate Conditional Split configuration.

---

### Check 8 — Date Coverage Check
**What:** Confirm dim_date has no gaps between 2020-01-01 and today.

**Pass condition:** Every date from 2020-01-01 to GETDATE() exists in dim_date with no missing days.

**Failure means:** dim_date generation script missed a range — re-run the Script Task.

---

### Check 9 — Monotonic Totals Check
**What:** Confirm total_cases and total_deaths never decrease day over day for any country.

**Pass condition:** 0 country-date pairs where today's total < yesterday's total.

**Failure means:** Source data had a correction (OWID sometimes revises historical data downward) — log as known anomaly and document.

---

## Pass / Fail Summary Template

Run this after every load and record the results:

| Check | Result | Rows Failed | Notes |
|---|---|---|---|
| 1. Row count reconciliation | PASS / FAIL | | |
| 2. Null FK check | PASS / FAIL | | |
| 3. Duplicate key check | PASS / FAIL | | |
| 4. Referential integrity | PASS / FAIL | | |
| 5. Aggregate reconciliation | PASS / FAIL | | |
| 6. DQ reject audit | PASS / FAIL | | |
| 7. Negative value check | PASS / FAIL | | |
| 8. Date coverage check | PASS / FAIL | | |
| 9. Monotonic totals check | PASS / FAIL | | |

**All 9 must PASS before proceeding to Phase 4 analytics.**
