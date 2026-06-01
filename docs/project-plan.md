# COVID-19 ETL Data Engineering Project Plan

## Project Overview

| Item | Detail |
|---|---|
| **Project Name** | COVID-19 ETL Data Engineering Project |
| **Owner** | Atul Kamble |
| **Start Date** | 2026-05-28 |
| **Goal** | Learn data engineering by building a full ETL pipeline |
| **GitHub Repo** | [github.com/AtulKamble03/covid-etl-project](https://github.com/AtulKamble03/covid-etl-project) |
| **Final Stack** | SSIS + SQL Server (local) → Snowflake (cloud) |

---

## Datasets

| File | Purpose | Null Risk |
|---|---|---|
| `owid_covid_compact.csv` | Core cases, deaths, country metadata | Low (cases/deaths ~3% null) |
| `hospital.csv` | Hospitalization & ICU daily occupancy and admissions | High (~93% null — not all countries report) |
| `vaccinations_global.csv` | Full vaccination metrics including rolling averages | Medium |

**Data source:** [Our World in Data — COVID-19](https://ourworldindata.org/covid-deaths)
**License:** Creative Commons BY 4.0 — safe for personal and corporate learning with attribution.
**GDPR:** Country-level aggregate data only — no PII, no individual records. GDPR does not apply.

---

## Tech Stack

| Tool | Purpose | Cost |
|---|---|---|
| SQL Server Developer Edition | Local data warehouse | Free |
| SSMS | Query, manage, verify loaded data | Free |
| Visual Studio Community + SSIS extension | Design and build SSIS packages | Free |
| SSIS (Integration Services) | ETL — extract, transform, load | Free (included with SQL Server) |
| Snowflake | Cloud data warehouse (Phase 5) | Free trial ($400 credits) |
| Azure (optional) | Cloud deployment | $200 credits |

---

## Business Requirements

> Full Q&A detail: [docs/requirements.md](requirements.md)
> Schema rationale: [docs/schema-design-rationale.md](schema-design-rationale.md)

**Audience:** General public — to understand COVID-19 situation by country and identify where vaccination supply is needed.
**Granularity:** Daily (country × day) with weekly and monthly roll-ups at query time.
**Slice by:** Country, Continent, Date, Month, Quarter.
**Time period:** 2020-01-01 to present.

| # | Report |
|---|---|
| 1 | Weekly Continental Summary — WoW % change, new cases, hospitalisations, ICU |
| 2 | Geographic Map View — total cases/deaths/vaccinations per country |
| 3 | Cases Over Time — 7d, 28d, cumulative, vaccine impact on deaths |
| 4 | Continental Aggregates — total cases per continent |
| 5 | Deaths — 7d, 28d, CFR, trend |
| 6 | Vaccination — coverage %, supply gaps, rolling 6m/9m/12m trends |
| 7 | Hospitalization & ICU — occupancy, weekly admissions, per million |
| 8 | Testing — total tests, positivity rate, 7d smoothed (82% null — limited coverage) |

---

## Project Phases

---

### Phase 1 — Explore and Understand the Dataset
**Status: ✅ Complete**

| Task | Done? |
|---|---|
| Download all 3 CSV files into `data/` folder | ✅ |
| Understand column structure — cases, deaths, vaccinations, hospitalisations | ✅ |
| Identify data quality issues — nulls, aggregate rows (World/Africa), negative values | ✅ |
| Document null coverage per column (82% for tests, 93% for hospitalisations) | ✅ |
| Confirm OWID pre-computed columns (smoothed, per-million, per-hundred, rolling avg) | ✅ |
| Identify join key differences across files (ISO-3 vs country name) | ✅ |

---

### Phase 2 — Design the Data Warehouse
**Status: ✅ Complete**

| Task | Done? |
|---|---|
| Design star schema — 2 dims, 3 facts, grain = country × day | ✅ |
| Define all table columns, data types, constraints | ✅ |
| Write `sql/create_tables.sql` — SQL Server DDL (SQL Server syntax, not PostgreSQL) | ✅ |
| Add partition function and scheme — fact tables partitioned by year (2020–2026+) | ✅ |
| Design DQ rules — 10 validation rules (DQ-CAST, DQ-01 to DQ-05, DQ-09, DQ-10) | ✅ |
| Design reject table (`dq_rejected_rows`) with rule_id taxonomy | ✅ |
| Design ETL run log table (`etl_run_log`) for row count tracking per run | ✅ |
| Write `sql/usp_verify_etl_load.sql` — 11-check post-load verification SP | ✅ |
| Write HLD — 4-layer architecture, design principles | ✅ |
| Write LLD — full SSIS data flows (8 steps per fact flow), field lineage | ✅ |
| Complete design review — 15 gaps identified and fixed | ✅ |

---

### Phase 3 — Build the SSIS ETL Package
**Status: 🔧 In Progress**

**Pre-requisite:** ✅ Met — `covid_dw` database created, all 7 tables verified, stored procedure deployed.

#### 3.1 — Setup
| Task | Done? |
|---|---|
| Run `sql/create_tables.sql` in SSMS — create `covid_dw` database and all tables | ✅ |
| Run `sql/usp_verify_etl_load.sql` in SSMS — deploy stored procedure | ✅ |
| Create new SSIS project in Visual Studio — save as `ssis/covid_etl.dtsx` | ✅ |
| Configure Flat File Connection Manager for each CSV (`data/` folder path) | ✅ |
| Configure OLE DB Connection Manager for SQL Server (`covid_dw`) — use MSOLEDBSQL provider | ✅ |

#### 3.2 — Build dim_date (Flow 1)
| Task | Done? |
|---|---|
| Add Execute SQL Task — `TRUNCATE TABLE dbo.dim_date` | ✅ |
| Add Script Task — C# generates dates 2020-01-01 → today, inserts into dim_date | ✅ |
| Fix: use hardcoded ADO.NET connection string (OLE DB string not compatible with SqlConnection) | ✅ |
| Fix: replace ISOWeek.GetWeekOfYear() with Calendar.GetWeekOfYear() (.NET Framework compat) | ✅ |
| Run and verify — both tasks green, package finished: Success | ✅ |

#### 3.3 — Build dim_location (Flow 2)
| Task | Done? |
|---|---|
| Add Data Flow Task to Control Flow, connect from `Generate dim_date` | ✅ |
| Add Flat File Source → `FF_CompactCSV` | ✅ |
| Add Conditional Split — filter `continent IS NULL` (DQ-03) → `Reject_Aggregates` | ✅ |
| Add Sort — sort by `code` ASC, enable "Remove rows with duplicate sort values" | ✅ |
| Add Data Conversion — population (→DT_I8), all others (→DT_R8 double-precision float) | ✅ |
| Add Derived Column — 8 expressions handling empty string → NULL before type cast | ✅ |
| Add OLE DB Destination → `dbo.dim_location`, map `_conv` columns + pass-through strings | ✅ |
| Add Execute SQL Task (Delete dim_location) before Data Flow — DELETE not TRUNCATE | ✅ |
| Fix: code column VARCHAR(10) not CHAR(3) — OWID_KOS and OWID_TRS are 8-char codes | ✅ |
| Fix: country/continent VARCHAR not NVARCHAR — DT_STR compatible, no unicode conversion needed | ✅ |
| Run and verify — 248 rows in dim_location ✅ | ✅ |

> **Execution model:** Flows 3, 4, 5 run in PARALLEL after dim_location completes. In SSIS Control Flow, draw one green arrow from `Load dim_location` to each of the three Truncate tasks (3a, 4a, 5a). Draw green arrows from each Log task (3c, 4c, 5c) into `usp_verify_etl_load` — SSIS AND precedence waits for all three before running verification.

#### 3.4 — Build fact_covid_cases (Flow 3) [PARALLEL branch 1]
| Task | Done? |
|---|---|
| Add Execute SQL Task (3a) — `TRUNCATE TABLE fact_covid_cases` | ✅ |
| Add Data Flow Task (3b) — source: `owid_covid_compact.csv` | ✅ |
| Set Text Qualifier to `"` in FF_CompactCSV — fixes rows with commas in country names | ✅ |
| Set `date` column to DT_DBDATE in FF_CompactCSV — avoids cast failure in Derived Column | ✅ |
| Step 1: Sort on (country, date), enable dedup | ✅ |
| Step 2: Derived Column — `[date]` pass-through, `(DT_I2)YEAR([date])` → record_year, 13 numeric columns with `""?NULL(DT_R8):(DT_R8)` pattern | ✅ |
| Step 3: Conditional Split — 7 DQ rules with ISNULL guards on nullable columns | ✅ |
| Step 4: Lookup location_id (dim_location, join on country) | ✅ |
| Step 5: Lookup date_id (dim_date, SQL query with CAST(date AS DATETIME)) | ✅ |
| Step 6: OLE DB Destination → `fact_covid_cases` | ✅ |
| Verify — 484,751 rows loaded, all 7 partitions populated (2020-2026+) | ✅ |

#### 3.5 — Build fact_vaccination (Flow 4) [PARALLEL branch 2]
| Task | Done? |
|---|---|
| Add Execute SQL Task (4a) — `TRUNCATE TABLE fact_vaccination` | ✅ |
| Add Data Flow Task (4b) — source: `vaccinations_global.csv` | ✅ |
| Set Text Qualifier `"` and date=DT_DBDATE in FF_Vaccinations | ✅ |
| Derived Column: date pass-through, `(DT_I2)YEAR([date])` → record_year, 12 metric null-safe conversions | ✅ |
| No Conditional Split needed — no empty dates, no future dates in vaccination CSV | ✅ |
| Lookup location_id → dim_location (country name join) | ✅ |
| date_id computed via DATEDIFF in Derived Column (VS 2022 Lookup dialog bug workaround) | ✅ |
| Fix: dim_date Script Task updated to use IDENTITY_INSERT with explicit date_id (1,2,3...) | ✅ |
| Fix: Added DBCC CHECKIDENT → changed to IDENTITY INSERT approach for reliable reseeding | ✅ |
| Fix: Added `Truncate All Facts` as first Control Flow task — clears facts before dims are deleted | ✅ |
| Verify — 197,657 rows loaded into fact_vaccination ✅ | ✅ |

#### 3.6 — Build fact_hospitalization (Flow 5) [PARALLEL branch 3]
| Task | Done? |
|---|---|
| Add Execute SQL Task (5a) — `TRUNCATE TABLE fact_hospitalization` | 🔲 |
| Add Data Flow Task (5b) — source: `hospital.csv` | 🔲 |
| Step 1: Row Count + Sort on (country_code, date), enable dedup | 🔲 |
| Step 2: Data Conversion (string→DATE, string→FLOAT), cast error → redirect (DQ-CAST) | 🔲 |
| Step 3: Derived Column — `record_year = YEAR([date])` | 🔲 |
| Step 4: Conditional Split — DQ-01, DQ-02 only | 🔲 |
| Step 5: Lookup `country_code` → `dim_location.code` → `location_id`, no-match → dq_rejected_rows | 🔲 |
| Step 6: Lookup `date` → `dim_date.date` → `date_id`, no-match → dq_rejected_rows | 🔲 |
| Step 7: Row Count Loaded + Row Count Rejected | 🔲 |
| Step 8: OLE DB Destination → `fact_hospitalization` + OLE DB Destination → `dq_rejected_rows` | 🔲 |
| Add Execute SQL Task (5c) — INSERT into `etl_run_log` | 🔲 |

#### 3.7 — Wire parallel branches + Post-Load Verification (Flow 6)
| Task | Done? |
|---|---|
| Draw green arrow from `Load dim_location` → `Truncate fact_covid_cases` (3a) | 🔲 |
| Draw green arrow from `Load dim_location` → `Truncate fact_vaccination` (4a) | 🔲 |
| Draw green arrow from `Load dim_location` → `Truncate fact_hospitalization` (5a) | 🔲 |
| Draw green arrow from `Log counts (3c)` → `usp_verify_etl_load` | 🔲 |
| Draw green arrow from `Log counts (4c)` → `usp_verify_etl_load` | 🔲 |
| Draw green arrow from `Log counts (5c)` → `usp_verify_etl_load` | 🔲 |

#### 3.8 — Post-Load Verification
| Task | Done? |
|---|---|
| Add Execute SQL Task (Step 6) — `EXEC usp_verify_etl_load` | 🔲 |
| Configure: On failure → fail the package | 🔲 |

#### 3.8 — Test and Validate
| Task | Done? |
|---|---|
| Run full SSIS package end-to-end | 🔲 |
| Confirm all 6 critical checks PASS (2, 3, 4, 7, 8, 10) | 🔲 |
| Review `etl_run_log` — check rows extracted / loaded / rejected per flow | 🔲 |
| Review `dq_rejected_rows` — confirm only expected rejects (DQ-03 aggregate rows) | 🔲 |
| Check partition row counts in SQL Server (use the inspection query in `create_tables.sql`) | 🔲 |
| Record results in Pass/Fail Summary Template (`docs/testing.md`) | 🔲 |

---

### Phase 4 — Analytics and Dashboard
**Status: 🔲 Not Started**

**Pre-requisite:** Phase 3 complete — all 6 critical verification checks passing.

#### 4.1 — SQL Queries (SSMS)
| Task | Done? |
|---|---|
| Write Report 1 — weekly continental summary with WoW % change | 🔲 |
| Write Report 2 — geographic map view (cases/deaths/vaccinations per country) | 🔲 |
| Write Report 3 — cases over time (7d, 28d, cumulative) | 🔲 |
| Write Report 4 — continental aggregates (total cases per continent) | 🔲 |
| Write Report 5 — deaths (7d, 28d, CFR by country) | 🔲 |
| Write Report 6 — vaccination coverage, supply gaps, rolling trends | 🔲 |
| Write Report 7 — hospitalisation and ICU occupancy | 🔲 |
| Write Report 8 — testing (positivity rate, 7d smoothed) | 🔲 |
| Save all queries to `sql/analytical_queries.sql` | 🔲 |

#### 4.2 — Dashboard
| Task | Done? |
|---|---|
| Connect Power BI (or SSRS) to `covid_dw` on local SQL Server | 🔲 |
| Build one visual per report | 🔲 |
| Add slicers — Country, Continent, Date range | 🔲 |

---

### Phase 5 — Migrate to Snowflake
**Status: 🔲 Not Started**

**Pre-requisite:** Phase 4 complete — analytics working end-to-end on SQL Server.

| Task | Done? |
|---|---|
| Sign up for Snowflake free trial | 🔲 |
| Recreate schema in Snowflake (adapt `create_tables.sql` — remove partition syntax, Snowflake auto-partitions) | 🔲 |
| Install Snowflake ODBC driver | 🔲 |
| Update SSIS OLE DB Connection Manager to point to Snowflake | 🔲 |
| Re-run SSIS package — validate data loaded into Snowflake | 🔲 |
| Run all 8 analytical queries in Snowflake — confirm same results as SQL Server | 🔲 |

---

### Phase 6 — Schedule and Deploy (Bonus)
**Status: 🔲 Not Started**

| Task | Done? |
|---|---|
| Create SQL Server Agent job to run SSIS package daily | 🔲 |
| Set job schedule — e.g. 6:00 AM daily (OWID publishes updates overnight) | 🔲 |
| Configure job failure alert (email or Windows Event Log) | 🔲 |
| (Optional) Deploy to Azure — Azure Data Factory or Azure SSIS IR | 🔲 |

---

## Skills You Will Learn

| Skill | Phase |
|---|---|
| Star schema design (Kimball dimensional modelling) | ✅ Phase 2 |
| SQL Server DDL — partitioning, constraints, indexes | ✅ Phase 2 |
| ETL pipeline design — DQ rules, reject handling, lineage | ✅ Phase 2 |
| SSIS Control Flow — Execute SQL Task, Script Task, sequencing | Phase 3 |
| SSIS Data Flow — Flat File Source, Sort, Data Conversion, Derived Column, Conditional Split, Lookup, Row Count, OLE DB Destination | Phase 3 |
| Post-load verification with stored procedures | Phase 3 |
| SQL Server partitioning — partition function, scheme, clustered index | Phase 3 |
| Analytical SQL — window functions, rolling averages, CFR, WoW % change | Phase 4 |
| Power BI / SSRS reporting and dashboards | Phase 4 |
| Snowflake cloud data warehouse | Phase 5 |
| Pipeline scheduling — SQL Server Agent | Phase 6 |
