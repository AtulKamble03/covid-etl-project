# Low Level Design (LLD)

## SSIS Control Flow — Overall Sequence

Two execution patterns are used deliberately:

- **Serial** — Steps 1 and 2 (dimensions). dim_date and dim_location must exist before any fact table loads. Foreign key constraints enforce this order.
- **Parallel** — Steps 3, 4, 5 (fact tables). Once dimensions are loaded, all three fact flows run simultaneously. They read different source files, write to different tables, and have no dependency on each other. This reduces total load time by ~66% compared to running them serially.
- **Re-synchronize** — Step 6 (verification). Three green arrows converge into usp_verify_etl_load. SSIS uses AND logic — the verification task does not start until all three parallel branches have completed successfully.

```
┌──────────────────────────────────────────────────┐
│  STEP 1 — Load dim_date          [SERIAL]        │
│  Type: Execute SQL + Script Task                 │
│  Truncate → generate 2020-01-01 to today         │
└───────────────────────┬──────────────────────────┘
                        │ Success
                        ▼
┌──────────────────────────────────────────────────┐
│  STEP 2 — Load dim_location      [SERIAL]        │
│  Type: Data Flow Task                            │
│  Source: owid_covid_compact.csv                  │
│  Filter → Deduplicate → Type Cast → Upsert       │
└──────┬─────────────────┬──────────────┬──────────┘
       │ Success         │ Success      │ Success
       ▼                 ▼              ▼
┌────────────┐    ┌────────────┐  ┌────────────┐
│  STEP 3    │    │  STEP 4    │  │  STEP 5    │
│  fact_     │    │  fact_     │  │  fact_     │
│  covid_    │    │  vaccination│  │  hospital- │
│  cases     │    │            │  │  ization   │
│            │    │            │  │            │
│  [PARALLEL]│    │  [PARALLEL]│  │  [PARALLEL]│
│            │    │            │  │            │
│  3a TRUNC  │    │  4a TRUNC  │  │  5a TRUNC  │
│  3b LOAD   │    │  4b LOAD   │  │  5b LOAD   │
│  3c LOG    │    │  4c LOG    │  │  5c LOG    │
└─────┬──────┘    └──────┬─────┘  └──────┬─────┘
      │ Success          │ Success        │ Success
      └──────────────────┴────────────────┘
                         │ All 3 must succeed (AND)
                         ▼
┌──────────────────────────────────────────────────┐
│  STEP 6 — Post-Load Verification  [SERIAL]       │
│  Type: Execute SQL Task                          │
│  EXEC usp_verify_etl_load                        │
│  11 checks → PASS continues / FAIL raises error  │
└──────────────────────────────────────────────────┘
```

### How to implement parallel execution in SSIS

In the Control Flow canvas:
1. From `Load dim_location`, draw **three separate green arrows** — one to each of the three fact flow starting tasks (Truncate fact_covid_cases, Truncate fact_vaccination, Truncate fact_hospitalization)
2. SSIS will run all three branches simultaneously once dim_location completes
3. From the **last task of each branch** (the Log counts tasks 3c, 4c, 5c), draw green arrows **into** `usp_verify_etl_load`
4. SSIS uses AND precedence by default — verification waits for all three incoming arrows to be green before starting

---

## Individual Data Flow Diagrams

Each box is one SSIS component. The left path = good rows → warehouse. The right path = bad rows → reject table.

---

### Flow 1 — dim_location

```
  EXTRACT                TRANSFORM                          LOAD
  ───────────────────────────────────────────────────────────────────
  ┌──────────────┐
  │ Flat File    │
  │ Source       │  owid_covid_compact.csv (all columns)
  └──────┬───────┘
         │
         ▼
  ┌──────────────┐     continent IS NULL?
  │ Conditional  │──────── YES ──────────────────────▶ ┌─────────────────┐
  │ Split        │                                      │ dq_rejected_rows│
  │ (DQ-03)      │                                      └─────────────────┘
  └──────┬───────┘
         │ NO (continent has value = real country)
         ▼
  ┌──────────────┐
  │ Sort +       │  Deduplicate — keep one row per country
  │ Aggregate    │  (country metadata is same across all dates)
  └──────┬───────┘
         │
         ▼
  ┌──────────────┐  population: float → BIGINT
  │ Data         │  population_density, median_age,
  │ Conversion   │  gdp_per_capita, life_expectancy,
  │              │  diabetes_prevalence, etc: string → FLOAT
  └──────┬───────┘
         │
         ▼
  ┌──────────────┐
  │ OLE DB       │──────────────────────────────────▶ ┌─────────────────┐
  │ Destination  │  Upsert by code (ISO-3)             │  dim_location   │
  └──────────────┘                                     │  (SQL Server)   │
                                                       └─────────────────┘
```

---

### Flow 2 — dim_date

```
  GENERATE               TRANSFORM                          LOAD
  ───────────────────────────────────────────────────────────────────
  ┌──────────────┐
  │ Script Task  │  Generates date series
  │              │  2020-01-01 → today
  │ (no CSV)     │  using recursive loop
  └──────┬───────┘
         │
         ▼
  ┌──────────────┐  year     = YEAR(date)
  │ Derived      │  month    = MONTH(date)
  │ Column       │  month_name = DATENAME(month, date)
  │              │  quarter  = 'Q' + DATEPART(quarter, date)
  │              │  week_number = DATEPART(iso_week, date)
  │              │  day_of_week = DATENAME(weekday, date)
  │              │  is_weekend  = 1 if Sat/Sun else 0
  └──────┬───────┘
         │
         ▼
  ┌──────────────┐
  │ OLE DB       │──────────────────────────────────▶ ┌─────────────────┐
  │ Destination  │  Truncate + reload every run        │  dim_date       │
  └──────────────┘                                     │  (SQL Server)   │
                                                       └─────────────────┘
```

---

### Flow 3 — fact_covid_cases

```
  EXTRACT                TRANSFORM                          LOAD
  ───────────────────────────────────────────────────────────────────
  ┌──────────────┐
  │ Flat File    │
  │ Source       │  owid_covid_compact.csv
  └──────┬───────┘
         │
         ▼
  ┌──────────────┐  date: string → DATE
  │ Data         │  new_cases, total_cases,
  │ Conversion   │  new_deaths, total_deaths,
  │              │  and all other metrics: string → FLOAT
  └──────┬───────┘
         │
         ▼
  ┌──────────────┐  DQ-01: date IS NULL     ──┐
  │ Conditional  │  DQ-02: date > today     ──┤──▶ ┌─────────────────┐
  │ Split        │  DQ-03: continent IS NULL──┤    │ dq_rejected_rows│
  │ (5 DQ rules) │  DQ-04: new_cases < 0   ──┤    └─────────────────┘
  │              │  DQ-05: new_deaths < 0  ──┘
  └──────┬───────┘
         │ PASS (all 5 rules satisfied)
         ▼
  ┌──────────────┐  Input : country (string)
  │ Lookup       │  Table : dim_location
  │ location_id  │  Match : country = country
  │              │  Output: location_id (INT)
  │              │  No match → dq_rejected_rows
  └──────┬───────┘
         │
         ▼
  ┌──────────────┐  Input : date (DATE)
  │ Lookup       │  Table : dim_date
  │ date_id      │  Match : date = date
  │              │  Output: date_id (INT)
  │              │  No match → dq_rejected_rows
  └──────┬───────┘
         │
         ▼
  ┌──────────────┐
  │ OLE DB       │──────────────────────────────────▶ ┌─────────────────┐
  │ Destination  │                                     │fact_covid_cases │
  └──────────────┘                                     │  (SQL Server)   │
                                                       └─────────────────┘
```

---

### Flow 4 — fact_vaccination

```
  EXTRACT                TRANSFORM                          LOAD
  ───────────────────────────────────────────────────────────────────
  ┌──────────────┐
  │ Flat File    │
  │ Source       │  vaccinations_global.csv
  └──────┬───────┘
         │
         ▼
  ┌──────────────┐  date: string → DATE
  │ Data         │  all vaccination metrics:
  │ Conversion   │  string → FLOAT
  └──────┬───────┘
         │
         ▼
  ┌──────────────┐  DQ-01: date IS NULL  ──┐
  │ Conditional  │  DQ-02: date > today  ──┴──▶ ┌─────────────────┐
  │ Split        │                               │ dq_rejected_rows│
  │ (2 DQ rules) │                               └─────────────────┘
  └──────┬───────┘
         │ PASS
         ▼
  ┌──────────────┐  Input : country (string)
  │ Lookup       │  Table : dim_location        ⚠ No ISO code in
  │ location_id  │  Match : country = country     this file — name
  │              │  Output: location_id (INT)     match only
  │              │  No match → dq_rejected_rows
  └──────┬───────┘
         │
         ▼
  ┌──────────────┐  Input : date (DATE)
  │ Lookup       │  Table : dim_date
  │ date_id      │  Match : date = date
  │              │  Output: date_id (INT)
  └──────┬───────┘
         │
         ▼
  ┌──────────────┐
  │ OLE DB       │──────────────────────────────────▶ ┌─────────────────┐
  │ Destination  │                                     │fact_vaccination │
  └──────────────┘                                     │  (SQL Server)   │
                                                       └─────────────────┘
```

---

### Flow 5 — fact_hospitalization

```
  EXTRACT                TRANSFORM                          LOAD
  ───────────────────────────────────────────────────────────────────
  ┌──────────────┐
  │ Flat File    │
  │ Source       │  hospital.csv
  └──────┬───────┘
         │
         ▼
  ┌──────────────┐  date: string → DATE
  │ Data         │  all hospital/ICU metrics:
  │ Conversion   │  string → FLOAT
  └──────┬───────┘
         │
         ▼
  ┌──────────────┐  DQ-01: date IS NULL  ──┐
  │ Conditional  │  DQ-02: date > today  ──┴──▶ ┌─────────────────┐
  │ Split        │                               │ dq_rejected_rows│
  │ (2 DQ rules) │                               └─────────────────┘
  └──────┬───────┘
         │ PASS
         ▼
  ┌──────────────┐  Input : country_code (ISO-3)
  │ Lookup       │  Table : dim_location        ✅ ISO-3 code match
  │ location_id  │  Match : country_code = code   more reliable than
  │              │  Output: location_id (INT)     name matching
  │              │  No match → dq_rejected_rows
  └──────┬───────┘
         │
         ▼
  ┌──────────────┐  Input : date (DATE)
  │ Lookup       │  Table : dim_date
  │ date_id      │  Match : date = date
  │              │  Output: date_id (INT)
  └──────┬───────┘
         │
         ▼
  ┌──────────────┐
  │ OLE DB       │──────────────────────────────────▶ ┌──────────────────────┐
  │ Destination  │                                     │fact_hospitalization  │
  └──────────────┘                                     │  (SQL Server)        │
                                                       └──────────────────────┘
```

---

## Star Schema

```
                    ┌──────────────┐
                    │   dim_date   │
                    │  date_id PK  │
                    └──────┬───────┘
                           │
         ┌─────────────────┼──────────────────┐
         │                 │                  │
         ▼                 ▼                  ▼
┌─────────────────┐ ┌──────────────────┐ ┌────────────────────┐
│fact_covid_cases │ │ fact_vaccination  │ │fact_hospitalization │
│ location_id FK  │ │  location_id FK  │ │  location_id FK    │
│ date_id FK      │ │  date_id FK      │ │  date_id FK        │
└────────┬────────┘ └────────┬─────────┘ └──────────┬─────────┘
         │                   │                       │
         └───────────────────┼───────────────────────┘
                             ▼
                    ┌─────────────────┐
                    │  dim_location   │
                    │ location_id PK  │
                    └─────────────────┘
```

## Dimension Tables

### dim_location
Source: `owid_covid_compact.csv`

| Column | Type | Notes |
|---|---|---|
| `location_id` | INT IDENTITY PK | Surrogate key |
| `country` | VARCHAR(100) | Country name — VARCHAR (not NVARCHAR): COVID names are ASCII, matches DT_STR from Flat File Source |
| `code` | VARCHAR(10) | ISO-3 or OWID code — VARCHAR(10) not CHAR(3): OWID uses 8-char codes (e.g. `OWID_KOS` for Kosovo, `OWID_TRS` for Transnistria) |
| `continent` | VARCHAR(50) | Africa, Asia, Europe, North America, Oceania, South America — VARCHAR for same reason as country |
| `population` | BIGINT | Whole numbers in CSV — Derived Column casts via `(DT_I8)` |
| `population_density` | FLOAT | Decimal values in CSV — Derived Column casts via `(DT_R8)` |
| `median_age` | FLOAT | |
| `life_expectancy` | FLOAT | |
| `gdp_per_capita` | FLOAT | USD — 22% null across countries |
| `diabetes_prevalence` | FLOAT | % of population |
| `handwashing_facilities` | FLOAT | % with access — 52% null |
| `hospital_beds_per_thousand` | FLOAT | 34% null |

### dim_date
Source: Generated (all dates from 2020-01-01 to current)

| Column | Type | Notes |
|---|---|---|
| `date_id` | INT IDENTITY PK | Surrogate key |
| `date` | DATE | |
| `year` | SMALLINT | |
| `month` | TINYINT | |
| `month_name` | NVARCHAR(10) | January … December |
| `quarter` | CHAR(2) | Q1, Q2, Q3, Q4 |
| `week_number` | TINYINT | ISO week number |
| `day_of_week` | NVARCHAR(10) | Monday … Sunday |
| `is_weekend` | BIT | 1 = weekend |

## Fact Tables

### fact_covid_cases
Source: `owid_covid_compact.csv` | Grain: country × day

| Column | Type | Notes |
|---|---|---|
| `case_id` | BIGINT IDENTITY PK | |
| `location_id` | INT FK | → dim_location |
| `date_id` | INT FK | → dim_date |
| `new_cases` | FLOAT | |
| `total_cases` | FLOAT | |
| `new_cases_smoothed` | FLOAT | 7-day smoothed |
| `new_cases_per_million` | FLOAT | |
| `new_deaths` | FLOAT | |
| `total_deaths` | FLOAT | |
| `new_deaths_smoothed` | FLOAT | 7-day smoothed |
| `new_deaths_per_million` | FLOAT | |
| `reproduction_rate` | FLOAT | Nullable |
| `stringency_index` | FLOAT | Nullable |
| `new_tests_smoothed` | FLOAT | Nullable (82% null) |
| `positive_rate` | FLOAT | Nullable (82% null) |
| `tests_per_case` | FLOAT | Nullable |

### fact_vaccination
Source: `vaccinations_global.csv` | Grain: country × day

| Column | Type | Notes |
|---|---|---|
| `vaccination_id` | BIGINT IDENTITY PK | |
| `location_id` | INT FK | → dim_location (join on country name) |
| `date_id` | INT FK | → dim_date |
| `total_vaccinations` | FLOAT | |
| `people_vaccinated` | FLOAT | |
| `people_fully_vaccinated` | FLOAT | |
| `total_boosters` | FLOAT | |
| `daily_vaccinations_smoothed` | FLOAT | |
| `people_vaccinated_per_hundred` | FLOAT | |
| `people_fully_vaccinated_per_hundred` | FLOAT | |
| `total_boosters_per_hundred` | FLOAT | |
| `people_unvaccinated` | FLOAT | |
| `rolling_vaccinations_6m` | FLOAT | |
| `rolling_vaccinations_9m` | FLOAT | |
| `rolling_vaccinations_12m` | FLOAT | |

### fact_hospitalization
Source: `hospital.csv` | Grain: country × day

| Column | Type | Notes |
|---|---|---|
| `hosp_id` | BIGINT IDENTITY PK | |
| `location_id` | INT FK | → dim_location (join on country_code = code) |
| `date_id` | INT FK | → dim_date |
| `daily_occupancy_hosp` | FLOAT | Current hospital patients |
| `daily_occupancy_hosp_per_1m` | FLOAT | |
| `daily_occupancy_icu` | FLOAT | Current ICU patients |
| `daily_occupancy_icu_per_1m` | FLOAT | |
| `weekly_admissions_hosp` | FLOAT | |
| `weekly_admissions_hosp_per_1m` | FLOAT | |
| `weekly_admissions_icu` | FLOAT | |
| `weekly_admissions_icu_per_1m` | FLOAT | |

## ETL Transformation Logic

This is the core of the design. Each SSIS Data Flow is described step by step — source columns, filters, type conversions, derived columns, lookups, and destination.

---

### Data Flow 1 — dim_location
**Source:** `owid_covid_compact.csv`

**Control Flow pre-step:** An Execute SQL Task (`Delete dim_location`) runs `DELETE FROM dbo.dim_location` before this Data Flow starts. This clears any existing rows so the load is always a clean full reload. TRUNCATE is not used — fact tables hold FK references to dim_location.

**Step 1 — Conditional Split (DQ-03)**
Remove aggregate/non-country rows:

| Condition | Output | Action |
|---|---|---|
| `ISNULL([continent])` | `Reject_Aggregates` | → dq_rejected_rows — removes "Africa", "World", "High-income countries", OWID income-group aggregates |
| All other rows | `Good_Rows` (default) | → continue |

> **Note:** OWID uses non-standard codes (`OWID_KOS` for Kosovo, `OWID_TRS` for Transnistria) for territories without official ISO-3 status. These HAVE continent values (Europe) so they pass this filter and are kept. The `code` column is VARCHAR(10) to accommodate these 8-character codes.

**Step 2 — Sort (Deduplication)**
Sort ascending by `code`. Enable **"Remove rows with duplicate sort values"**. The compact CSV has one row per country per day — Sort reduces 589k rows to one row per unique country code (248 rows after dedup).

**Step 3 — Derived Column (type conversion with null handling)**
CSV stores all values as strings. Empty strings `""` must be converted to NULL before inserting into numeric SQL Server columns — SSIS cannot implicitly convert `""` to FLOAT or BIGINT.

| Output Column | Expression | Target SQL Type |
|---|---|---|
| `pop_conv` | `[population] == "" ? NULL(DT_I8) : (DT_I8)[population]` | BIGINT |
| `pop_density_conv` | `[population_density] == "" ? NULL(DT_R8) : (DT_R8)[population_density]` | FLOAT |
| `median_age_conv` | `[median_age] == "" ? NULL(DT_R8) : (DT_R8)[median_age]` | FLOAT |
| `life_exp_conv` | `[life_expectancy] == "" ? NULL(DT_R8) : (DT_R8)[life_expectancy]` | FLOAT |
| `gdp_conv` | `[gdp_per_capita] == "" ? NULL(DT_R8) : (DT_R8)[gdp_per_capita]` | FLOAT |
| `diabetes_conv` | `[diabetes_prevalence] == "" ? NULL(DT_R8) : (DT_R8)[diabetes_prevalence]` | FLOAT |
| `handwashing_conv` | `[handwashing_facilities] == "" ? NULL(DT_R8) : (DT_R8)[handwashing_facilities]` | FLOAT |
| `hosp_beds_conv` | `[hospital_beds_per_thousand] == "" ? NULL(DT_R8) : (DT_R8)[hospital_beds_per_thousand]` | FLOAT |

> `country`, `code`, `continent` are VARCHAR in SQL Server and DT_STR in the Flat File Source — they pass through without conversion. No Data Conversion component is used; Derived Column handles all type casting.

**Step 4 — Column Mapping (source → target)**

| Input | Target Column (dim_location) | Notes |
|---|---|---|
| `country` | `country` | DT_STR → VARCHAR(100) direct |
| `code` | `code` | DT_STR → VARCHAR(10) direct |
| `continent` | `continent` | DT_STR → VARCHAR(50) direct |
| `pop_conv` | `population` | Derived Column output |
| `pop_density_conv` | `population_density` | Derived Column output |
| `median_age_conv` | `median_age` | Derived Column output |
| `life_exp_conv` | `life_expectancy` | Derived Column output |
| `gdp_conv` | `gdp_per_capita` | Derived Column output |
| `diabetes_conv` | `diabetes_prevalence` | Derived Column output |
| `handwashing_conv` | `handwashing_facilities` | Derived Column output |
| `hosp_beds_conv` | `hospital_beds_per_thousand` | Derived Column output |
| `location_id` | `<ignore>` | IDENTITY — SQL Server auto-generates |
| *(all other 50 columns)* | *(dropped)* | Not needed for dim_location |

**Step 5 — Load**
OLE DB Destination → `dbo.dim_location`, Fast Load mode. Inserts all 248 rows into the freshly-cleared table.

---

### Data Flow 2 — dim_date
**Source:** None — generated programmatically via SSIS Script Task

**Generation logic (T-SQL equivalent):**
```sql
-- Generate every date from 2020-01-01 to GETDATE()
WITH date_series AS (
    SELECT CAST('2020-01-01' AS DATE) AS date
    UNION ALL
    SELECT DATEADD(DAY, 1, date) FROM date_series
    WHERE date < CAST(GETDATE() AS DATE)
)
SELECT date INTO staging FROM date_series OPTION (MAXRECURSION 3000);
```

**Step 1 — Derived Column (all columns computed from date)**

| Target Column | Derivation Logic | Example |
|---|---|---|
| `year` | `YEAR(date)` | 2021 |
| `month` | `MONTH(date)` | 3 |
| `month_name` | `DATENAME(month, date)` | March |
| `quarter` | `'Q' + CAST(DATEPART(quarter, date) AS VARCHAR)` | Q1 |
| `week_number` | `DATEPART(iso_week, date)` | 11 |
| `day_of_week` | `DATENAME(weekday, date)` | Sunday |
| `is_weekend` | `CASE WHEN DATEPART(weekday,date) IN (1,7) THEN 1 ELSE 0 END` | 1 |

**Step 2 — Load**
`DELETE FROM dbo.dim_date` (not TRUNCATE) then reload every run. TRUNCATE is blocked by SQL Server when fact tables have FK references pointing to dim_date — even when those tables are empty. DELETE bypasses this restriction. dim_date has only ~2,344 rows so DELETE is equally fast.

---

### Data Flow 3 — fact_covid_cases
**Source:** `owid_covid_compact.csv`

**Step 1 — Row Count (Extracted) + Deduplication (Sort)**
Place a Row Count component immediately after the Flat File Source and store the count in the package variable `@[User::RowsExtracted]`. Then sort on (`country`, `date`) ascending with "Remove rows with duplicate sort values" enabled. If two rows share the same country + date, the first row in sort order is kept. A UNIQUE constraint on (`location_id`, `date_id`) in the database acts as a second-line safety net.

**FF_CompactCSV configuration required before this flow runs:**
- **Text Qualifier**: set to `"` (double quote) — the CSV contains country names with commas (e.g. "World excl. China, South Korea, Japan and Singapore"). Without a text qualifier, SSIS splits on those commas and corrupts downstream columns.
- **`date` column DataType**: set to `database date [DT_DBDATE]` in the Advanced tab — this avoids a Derived Column cast failure. SSIS's Flat File Source handles the "YYYY-MM-DD" → DT_DBDATE conversion reliably at the source level; casting DT_STR → DT_DBDATE inside a Derived Column expression fails at runtime.

**Step 2 — Derived Column (all type conversions + record_year)**

No Data Conversion component is used. A single Derived Column handles all conversions.

Since `date` is already DT_DBDATE from FF_CompactCSV, no casting is needed for date or record_year. Numeric metrics are still DT_STR from the source — use empty-string → NULL expressions.

| Output Column | Expression | Target SQL Type |
|---|---|---|
| `date_conv` | `[date]` | DATE — pass-through (already DT_DBDATE from FF_CompactCSV) |
| `record_year` | `(DT_I2)YEAR([date])` | SMALLINT — partition key |
| `new_cases_conv` | `[new_cases] == "" ? NULL(DT_R8) : (DT_R8)[new_cases]` | FLOAT |
| `total_cases_conv` | `[total_cases] == "" ? NULL(DT_R8) : (DT_R8)[total_cases]` | FLOAT |
| `new_cases_sm_conv` | `[new_cases_smoothed] == "" ? NULL(DT_R8) : (DT_R8)[new_cases_smoothed]` | FLOAT |
| `new_cases_pm_conv` | `[new_cases_per_million] == "" ? NULL(DT_R8) : (DT_R8)[new_cases_per_million]` | FLOAT |
| `new_deaths_conv` | `[new_deaths] == "" ? NULL(DT_R8) : (DT_R8)[new_deaths]` | FLOAT |
| `total_deaths_conv` | `[total_deaths] == "" ? NULL(DT_R8) : (DT_R8)[total_deaths]` | FLOAT |
| `new_deaths_sm_conv` | `[new_deaths_smoothed] == "" ? NULL(DT_R8) : (DT_R8)[new_deaths_smoothed]` | FLOAT |
| `new_deaths_pm_conv` | `[new_deaths_per_million] == "" ? NULL(DT_R8) : (DT_R8)[new_deaths_per_million]` | FLOAT |
| `repro_rate_conv` | `[reproduction_rate] == "" ? NULL(DT_R8) : (DT_R8)[reproduction_rate]` | FLOAT |
| `stringency_conv` | `[stringency_index] == "" ? NULL(DT_R8) : (DT_R8)[stringency_index]` | FLOAT |
| `tests_sm_conv` | `[new_tests_smoothed] == "" ? NULL(DT_R8) : (DT_R8)[new_tests_smoothed]` | FLOAT |
| `pos_rate_conv` | `[positive_rate] == "" ? NULL(DT_R8) : (DT_R8)[positive_rate]` | FLOAT |
| `tests_per_case_conv` | `[tests_per_case] == "" ? NULL(DT_R8) : (DT_R8)[tests_per_case]` | FLOAT |

> `country` and `continent` are DT_STR and map directly to VARCHAR columns — no conversion needed.

**Step 3 — DQ Filter (Conditional Split)**

> **Important:** In SSIS Conditional Split, `NULL < 0` evaluates to NULL (not false), and NULL is treated as an error — causing the component to fail. Any condition that compares a nullable column must include an explicit `!ISNULL()` guard. Only conditions 1 and 3 (`ISNULL()` checks) are naturally safe; conditions 4-7 require the guard.

| Output Name | Order | Expression | DQ Rule |
|---|---|---|---|
| `Reject_NullDate` | 1 | `ISNULL([date_conv])` | DQ-01 |
| `Reject_FutureDate` | 2 | `[date_conv] > (DT_DBDATE)GETDATE()` | DQ-02 |
| `Reject_NullContinent` | 3 | `ISNULL([continent]) \|\| [continent] == ""` | DQ-03 — catches both NULL and blank string continent (OWID aggregate rows use empty string, not NULL) |
| `Reject_NegCases` | 4 | `!ISNULL([new_cases_conv]) && [new_cases_conv] < 0` | DQ-04 |
| `Reject_NegDeaths` | 5 | `!ISNULL([new_deaths_conv]) && [new_deaths_conv] < 0` | DQ-05 |
| `Reject_BadPosRate` | 6 | `!ISNULL([pos_rate_conv]) && [pos_rate_conv] > 1` | DQ-09 |
| `Reject_BadStringency` | 7 | `!ISNULL([stringency_conv]) && [stringency_conv] > 100` | DQ-10 |
| `Good_Rows` | default | all other rows | |

**Step 4 — Lookup: resolve location_id**

| Lookup Input | Lookup Table | Match Column | Output |
|---|---|---|---|
| `country` | dim_location | `country` | `location_id` |
| No match | → dq_rejected_rows with note "country not found in dim_location" | | |

**Step 5 — Lookup: resolve date_id**

Use **SQL Query mode** in the Lookup Connection tab (not "Table or view") to cast the reference date column to DATETIME so it matches the DT_DBDATE input type:

```sql
SELECT date_id, CAST(date AS DATETIME) AS date FROM dbo.dim_date
```

| Lookup Input | Reference Column | Output |
|---|---|---|
| `date_conv` (DT_DBDATE) | `date` (DATETIME from query) | `date_id` |
| No match | → dq_rejected_rows with note "date not found in dim_date" | |

**Step 6 — Column Mapping (source → target)**

| Input Column | Target Column (fact_covid_cases) | Notes |
|---|---|---|
| `record_year` | `record_year` | Partition key — from Derived Column |
| *(lookup result)* | `location_id` | FK from dim_location |
| *(lookup result)* | `date_id` | FK from dim_date |
| `new_cases_conv` | `new_cases` | |
| `total_cases_conv` | `total_cases` | |
| `new_cases_sm_conv` | `new_cases_smoothed` | OWID pre-computed |
| `new_cases_pm_conv` | `new_cases_per_million` | OWID pre-computed |
| `new_deaths_conv` | `new_deaths` | |
| `total_deaths_conv` | `total_deaths` | |
| `new_deaths_sm_conv` | `new_deaths_smoothed` | OWID pre-computed |
| `new_deaths_pm_conv` | `new_deaths_per_million` | OWID pre-computed |
| `repro_rate_conv` | `reproduction_rate` | Nullable |
| `stringency_conv` | `stringency_index` | Nullable |
| `tests_sm_conv` | `new_tests_smoothed` | Nullable (82% null) |
| `pos_rate_conv` | `positive_rate` | Nullable (82% null) |
| `tests_per_case_conv` | `tests_per_case` | Nullable |
| `country`, `continent`, `code` + all others | *(dropped)* | Used for lookups and DQ only |

> **Null policy:** All metric columns (`new_cases`, `total_cases`, `new_deaths`, etc.) pass through as NULL when the source value is missing. NULL means the country did not report that day — it is never replaced with zero. See `docs/data-quality.md` for the full per-column null policy.

**Step 8 — Load + Row Count**
Place a Row Count component on the good-row path just before the OLE DB Destination (→ `@[User::RowsLoaded]`) and another on the rejected-row path just before the dq_rejected_rows Destination (→ `@[User::RowsRejected]`). An Execute SQL Task in the Control Flow runs `TRUNCATE TABLE fact_covid_cases` before this Data Flow starts; a second Execute SQL Task after it writes the three row count variables to `etl_run_log`. Re-running the package is safe — truncate clears all previous rows before each load.

---

### Data Flow 4 — fact_vaccination
**Source:** `vaccinations_global.csv`

**Step 1 — Row Count (Extracted) + Deduplication (Sort)**
Place a Row Count component immediately after the Flat File Source and store the count in `@[User::RowsExtracted]`. Then sort on (`country`, `date`) ascending with "Remove rows with duplicate sort values" enabled. First row in sort order is kept. The UNIQUE constraint on (`location_id`, `date_id`) acts as a second-line safety net.

**Step 2 — Data Conversion**

| Column | From | To |
|---|---|---|
| `date` | String | DATE |
| All numeric columns | String / float64 | FLOAT |

> **Cast failure handling:** Set Error and Truncation on every column to "Redirect row". Rows that fail any cast are redirected to `dq_rejected_rows` with rule ID `DQ-CAST`. Data Conversion runs before the DQ Filter so that `date > GETDATE()` compares DATE types, not strings.

**Step 3 — Derived Column (record_year)**

| Output Column | Expression | Data Type | Purpose |
|---|---|---|---|
| `record_year` | `YEAR([date])` | `DT_I2` | Partition key — routes row to correct year partition |

**Step 4 — DQ Filter (Conditional Split)**

| Condition | Action | DQ Rule |
|---|---|---|
| `date IS NULL` | → dq_rejected_rows | DQ-01 |
| `date > GETDATE()` | → dq_rejected_rows | DQ-02 |
| All other rows | → continue | |

> Note: No continent column in this file — DQ-03 does not apply here.

**Step 5 — Lookup: resolve location_id**

| Lookup Input | Lookup Table | Match Column | Output |
|---|---|---|---|
| `country` | dim_location | `country` | `location_id` |
| No match | → dq_rejected_rows | | |

> This file has NO ISO code — country name is the only join key. Watch for spelling differences.

**Step 6 — Lookup: resolve date_id**

| Lookup Input | Lookup Table | Match Column | Output |
|---|---|---|---|
| `date` | dim_date | `date` | `date_id` |
| No match | → dq_rejected_rows with note "date not found in dim_date" | | |

**Step 7 — Column Mapping (source → target)**

| Source Column (CSV) | Target Column (fact_vaccination) |
|---|---|
| *(derived)* | `record_year` |
| *(lookup result)* | `location_id` |
| *(lookup result)* | `date_id` |
| `total_vaccinations` | `total_vaccinations` |
| `people_vaccinated` | `people_vaccinated` |
| `people_fully_vaccinated` | `people_fully_vaccinated` |
| `total_boosters` | `total_boosters` |
| `daily_vaccinations_smoothed` | `daily_vaccinations_smoothed` |
| `people_vaccinated_per_hundred` | `people_vaccinated_per_hundred` |
| `people_fully_vaccinated_per_hundred` | `people_fully_vaccinated_per_hundred` |
| `total_boosters_per_hundred` | `total_boosters_per_hundred` |
| `people_unvaccinated` | `people_unvaccinated` |
| `rolling_vaccinations_6m` | `rolling_vaccinations_6m` |
| `rolling_vaccinations_9m` | `rolling_vaccinations_9m` |
| `rolling_vaccinations_12m` | `rolling_vaccinations_12m` |
| `country`, `date` + all others | *(dropped)* | |

> **Null policy:** All vaccination metric columns pass through as NULL when missing. NULL indicates the country had not yet started reporting that metric on that date (e.g., `total_boosters` is null before booster programmes began). Never replaced with zero. See `docs/data-quality.md`.

**Step 8 — Load + Row Count**
Place a Row Count component on the good-row path just before the OLE DB Destination (→ `@[User::RowsLoaded]`) and another on the rejected-row path (→ `@[User::RowsRejected]`). An Execute SQL Task in the Control Flow runs `TRUNCATE TABLE fact_vaccination` before this Data Flow starts; a second Execute SQL Task after it writes the three row count variables to `etl_run_log`. Re-running the package is safe — truncate clears all previous rows before each load.

---

### Data Flow 5 — fact_hospitalization
**Source:** `hospital.csv`

**Step 1 — Row Count (Extracted) + Deduplication (Sort)**
Place a Row Count component immediately after the Flat File Source and store the count in `@[User::RowsExtracted]`. Then sort on (`country_code`, `date`) ascending with "Remove rows with duplicate sort values" enabled. First row in sort order is kept. The UNIQUE constraint on (`location_id`, `date_id`) acts as a second-line safety net.

**Step 2 — Data Conversion**

| Column | From | To |
|---|---|---|
| `date` | String | DATE |
| All numeric columns | String / float64 | FLOAT |

> **Cast failure handling:** Set Error and Truncation on every column to "Redirect row". Rows that fail any cast are redirected to `dq_rejected_rows` with rule ID `DQ-CAST`. Data Conversion runs before the DQ Filter so that `date > GETDATE()` compares DATE types, not strings.

**Step 3 — Derived Column (record_year)**

| Output Column | Expression | Data Type | Purpose |
|---|---|---|---|
| `record_year` | `YEAR([date])` | `DT_I2` | Partition key — routes row to correct year partition |

**Step 4 — DQ Filter (Conditional Split)**

| Condition | Action | DQ Rule |
|---|---|---|
| `date IS NULL` | → dq_rejected_rows | DQ-01 |
| `date > GETDATE()` | → dq_rejected_rows | DQ-02 |
| All other rows | → continue | |

**Step 5 — Lookup: resolve location_id**

| Lookup Input | Lookup Table | Match Column | Output |
|---|---|---|---|
| `country_code` | dim_location | `code` | `location_id` |
| No match | → dq_rejected_rows | | |

> This file HAS an ISO-3 code (`country_code`) — use it. More reliable than country name matching.

**Step 6 — Lookup: resolve date_id**

| Lookup Input | Lookup Table | Match Column | Output |
|---|---|---|---|
| `date` | dim_date | `date` | `date_id` |
| No match | → dq_rejected_rows with note "date not found in dim_date" | | |

**Step 7 — Column Mapping (source → target)**

| Source Column (CSV) | Target Column (fact_hospitalization) |
|---|---|
| *(derived)* | `record_year` |
| *(lookup result)* | `location_id` |
| *(lookup result)* | `date_id` |
| `daily_occupancy_hosp` | `daily_occupancy_hosp` |
| `daily_occupancy_hosp_per_1m` | `daily_occupancy_hosp_per_1m` |
| `daily_occupancy_icu` | `daily_occupancy_icu` |
| `daily_occupancy_icu_per_1m` | `daily_occupancy_icu_per_1m` |
| `weekly_admissions_hosp` | `weekly_admissions_hosp` |
| `weekly_admissions_hosp_per_1m` | `weekly_admissions_hosp_per_1m` |
| `weekly_admissions_icu` | `weekly_admissions_icu` |
| `weekly_admissions_icu_per_1m` | `weekly_admissions_icu_per_1m` |
| `country`, `country_code`, `date` | *(dropped)* | |

> **Null policy:** All hospitalization metric columns pass through as NULL. ~93% of rows are null — only countries that actively report hospitalization data to OWID have values. NULL is the expected state for most rows, not an error. See `docs/data-quality.md`.

**Step 8 — Load + Row Count**
Place a Row Count component on the good-row path just before the OLE DB Destination (→ `@[User::RowsLoaded]`) and another on the rejected-row path (→ `@[User::RowsRejected]`). An Execute SQL Task in the Control Flow runs `TRUNCATE TABLE fact_hospitalization` before this Data Flow starts; a second Execute SQL Task after it writes the three row count variables to `etl_run_log`. Re-running the package is safe — truncate clears all previous rows before each load.

---

## SSIS Package Structure

```
covid_etl.dtsx
├── Control Flow
│   │
│   │   ◄── SERIAL ──►
│   ├── 1.  Load dim_date              (Execute SQL + Script Task — DELETE + generate dates)
│   │         ↓ Success
│   ├── 2a. Delete dim_location        (Execute SQL Task — DELETE FROM dbo.dim_location)
│   │         ↓ Success
│   ├── 2b. Load dim_location          (Data Flow — compact CSV, DELETE + full reload, 248 rows)
│   │         ↓ Success (3 arrows out — triggers all three parallel branches)
│   │
│   │   ◄────────────────── PARALLEL ──────────────────►
│   ├── 3a. Truncate fact_covid_cases  (Execute SQL Task)
│   ├── 3b. Load fact_covid_cases      (Data Flow — compact CSV)
│   ├── 3c. Log run counts             (Execute SQL Task → etl_run_log)
│   │
│   ├── 4a. Truncate fact_vaccination  (Execute SQL Task)
│   ├── 4b. Load fact_vaccination      (Data Flow — vaccinations_global.csv)
│   ├── 4c. Log run counts             (Execute SQL Task → etl_run_log)
│   │
│   ├── 5a. Truncate fact_hosp         (Execute SQL Task)
│   ├── 5b. Load fact_hospitalization  (Data Flow — hospital.csv)
│   ├── 5c. Log run counts             (Execute SQL Task → etl_run_log)
│   │         ↓ All 3 branches must succeed (AND precedence)
│   │
│   │   ◄── SERIAL ──►
│   └── 6.  Post-Load Verification     (Execute SQL Task — usp_verify_etl_load)
│
└── Each fact Data Flow contains
    ├── Flat File Source (CSV)
    ├── Row Count — Extracted          (→ @[User::RowsExtracted])
    ├── Sort                           (dedup on country + date)
    ├── Data Conversion                (type casting — error output → dq_rejected_rows)
    ├── Derived Column                 (record_year = YEAR([date]), type DT_I2)
    ├── Conditional Split              (DQ rules — good rows / rejected rows)
    ├── Lookup location_id             (no match → dq_rejected_rows)
    ├── Lookup date_id                 (no match → dq_rejected_rows)
    ├── Row Count — Loaded             (→ @[User::RowsLoaded], on good-row path)
    ├── Row Count — Rejected           (→ @[User::RowsRejected], on rejected-row path)
    ├── OLE DB Destination             (INSERT into target fact table — Fast Load, partitioned)
    └── OLE DB Destination             (INSERT into dq_rejected_rows)
```

## Join Keys Between Source Files

| Source A | Source B | Join Key |
|---|---|---|
| compact (`code`) | hospital (`country_code`) | ISO-3 code — most reliable |
| compact (`country`) | vaccinations_global (`country`) | Country name — watch for mismatches |
| All sources | dim_location | Resolved to `location_id` surrogate key in SSIS |

---

## ETL Design Decisions

Explicit decisions made during design — documented here so future implementers understand why the ETL is structured the way it is, and do not accidentally undo these choices.

---

### Decision 1 — No ETL-level aggregation

**Decision:** The ETL layer performs no GROUP BY, SUM, COUNT, or any other aggregation. All data is loaded at the lowest grain (country × day) as it exists in the source.

**Rationale:** Aggregating during ETL destroys granularity that may be needed later. Weekly, monthly, and continental rollups are computed at query time using `sql/analytical_queries.sql` and window functions in SSMS or Power BI. This keeps the warehouse flexible — any aggregation period or grouping can be answered from the stored grain without an ETL rerun.

**What this means in SSIS:** No Aggregate component is used in any fact Data Flow except the dim_location deduplication (Sort + Aggregate to keep one row per country — this is a dimension reduction, not an analytical aggregation).

---

### Decision 2 — OWID pre-computed fields are pass-through

**Decision:** Several columns in the source CSVs are already computed by OWID (7-day smoothed averages, per-million rates, per-hundred percentages, rolling vaccination totals). SSIS does not re-derive these — it casts them to FLOAT and loads them as-is.

**Columns affected:** `new_cases_smoothed`, `new_deaths_smoothed`, `new_cases_per_million`, `new_deaths_per_million`, `daily_vaccinations_smoothed`, `people_vaccinated_per_hundred`, `people_fully_vaccinated_per_hundred`, `total_boosters_per_hundred`, `rolling_vaccinations_6m/9m/12m`, all `_per_1m` hospitalization columns.

**Rationale:** OWID's calculations are well-documented and use the same population denominators consistently. Re-deriving them in SSIS would risk inconsistency (e.g., different population figures) and adds complexity for no benefit.

**What this means:** If OWID changes its smoothing method or per-million formula, the stored values in the warehouse will reflect the new method on the next full reload. No SSIS changes are needed.

---

### Decision 3 — Partitioning strategy

**Decision:** All three fact tables are partitioned by year using a `record_year SMALLINT` column as the partition key. Partitioning is implemented from the start as a learning exercise — the trigger threshold is > 100k rows, which `fact_covid_cases` (~450k rows) already exceeds.

**Partition design:**

| Component | Name | Detail |
|---|---|---|
| Partition column | `record_year SMALLINT NOT NULL` | Added to all 3 fact tables; derived from `date` by SSIS Derived Column |
| Partition function | `pf_covid_year` | `RANGE RIGHT FOR VALUES (2021, 2022, 2023, 2024, 2025, 2026)` — 7 partitions |
| Partition scheme | `ps_covid_year` | All partitions on `[PRIMARY]` filegroup (learning project) |
| Clustered index | `ci_fact_*` | `(record_year, location_id, date_id)` — aligned with partition scheme |
| PK | `NONCLUSTERED (surrogate_id, record_year)` | Must include partition key per SQL Server requirement |
| UNIQUE constraint | `NONCLUSTERED (location_id, date_id, record_year)` | Dedup enforcement; includes partition key |

**Partition map:**

| Partition | record_year values | Approx. rows (fact_covid_cases) |
|---|---|---|
| P1 | 2020 | ~70k |
| P2 | 2021 | ~80k |
| P3 | 2022 | ~80k |
| P4 | 2023 | ~80k |
| P5 | 2024 | ~80k |
| P6 | 2025 | ~60k |
| P7 | 2026+ | ~small (growing) |

**Partition elimination example:** A query filtering `WHERE d.year = 2022` joined to `fact_covid_cases` via `date_id` will, with the clustered index on `(record_year, ...)`, prune to P3 only — SQL Server skips the other 6 partitions entirely.

**How record_year is populated in SSIS:** A Derived Column component after Data Conversion computes `YEAR([date])` → `record_year` (output type `DT_I2`). This runs before the DQ Filter and Lookups.

**Phase 5 (Snowflake):** Snowflake uses automatic micro-partitioning — no manual partition design is needed. The `record_year` column can be kept as a query filter hint or dropped from the Snowflake schema.

**Production note:** In production, each partition would map to a separate filegroup on its own disk volume, enabling faster per-year backup/restore and partition switching for archival.

---

## Load Strategy and Idempotency

Defines how each table is loaded on every package run, and whether the package is safe to re-run.

| Table | Load Mode | Idempotent | Notes |
|---|---|---|---|
| `dim_date` | DELETE + full reload | Yes | Generated fresh every run. DELETE used instead of TRUNCATE — TRUNCATE is blocked by FK constraints from fact tables even when empty |
| `dim_location` | DELETE + full reload | Yes | DELETE then INSERT all 248 rows. DELETE used instead of TRUNCATE — fact tables hold FK references to this table |
| `fact_covid_cases` | Truncate + full reload | Yes | Execute SQL Task truncates before Data Flow inserts |
| `fact_vaccination` | Truncate + full reload | Yes | Execute SQL Task truncates before Data Flow inserts |
| `fact_hospitalization` | Truncate + full reload | Yes | Execute SQL Task truncates before Data Flow inserts |

**Rejection threshold:** The post-load verification (Step 6 — usp_verify_etl_load) includes a threshold check per source file. If unexpected rejects exceed 5% for fact_covid_cases or fact_hospitalization, or 10% for fact_vaccination, the procedure raises an error and fails the package. DQ-03 rejects (aggregate row removal) are excluded from the threshold — they are expected. See `docs/data-quality.md` for thresholds and the full SQL implementation.

**Late arriving data:** Because all tables use DELETE or TRUNCATE + full reload on every run, OWID historical corrections are automatically reflected on the next package execution — no special handling required.

**Deduplication rule:** If the source CSV contains two rows for the same country + date, the SSIS Sort component (Step 1 of each fact flow) removes the duplicate before any DQ check or lookup runs. The first row in ascending (country, date) sort order is kept. A UNIQUE constraint on (`location_id`, `date_id`) in each fact table enforces this at the database level as a safety net — any row that bypasses the Sort step will fail at insert and be routed to `dq_rejected_rows`.

**Re-run safety:** The package is safe to re-run. dim_date and dim_location are cleared with DELETE before each load. Fact tables use TRUNCATE before each load. Running the package twice on the same CSVs produces the same result with no duplicates.

**dim_location load strategy note:** The original design specified SCD Type 1 upsert (insert if not exists, skip if exists). During implementation, this was changed to DELETE + full reload for simplicity and idempotency. All 248 country rows are deleted and re-inserted on every run. This is equivalent for a full-refresh pipeline where the source is always the complete current dataset.

---

## Field Lineage Summary

Single consolidated view of every field's origin — source file, source column, SSIS transform applied, and target table/column. Use this to answer "where does this column come from?" without hunting through individual flow sections.

### dim_location

| Source File | Source Column | SSIS Transform | Target Column | Notes |
|---|---|---|---|---|
| owid_covid_compact.csv | `country` | Pass-through (DT_STR → VARCHAR) | `country` | No conversion — VARCHAR(100) accepts DT_STR directly |
| owid_covid_compact.csv | `code` | Pass-through (DT_STR → VARCHAR) | `code` | CSV column is `code` (not `iso_code`). VARCHAR(10) — accommodates OWID codes e.g. `OWID_KOS`, `OWID_TRS` |
| owid_covid_compact.csv | `continent` | Pass-through (DT_STR → VARCHAR) | `continent` | Null rows removed by DQ-03. VARCHAR(50) accepts DT_STR directly |
| owid_covid_compact.csv | `population` | Derived Column: `[population]==""?NULL(DT_I8):(DT_I8)[population]` | `population` | Empty string → NULL; CSV values are whole numbers (no decimals) |
| owid_covid_compact.csv | `population_density` | Derived Column: `[col]==""?NULL(DT_R8):(DT_R8)[col]` | `population_density` | 17/262 empty |
| owid_covid_compact.csv | `median_age` | Derived Column | `median_age` | 16/262 empty |
| owid_covid_compact.csv | `life_expectancy` | Derived Column | `life_expectancy` | 15/262 empty |
| owid_covid_compact.csv | `gdp_per_capita` | Derived Column | `gdp_per_capita` | 57/262 empty — 22% null |
| owid_covid_compact.csv | `diabetes_prevalence` | Derived Column | `diabetes_prevalence` | 47/262 empty |
| owid_covid_compact.csv | `handwashing_facilities` | Derived Column | `handwashing_facilities` | 138/262 empty — 52% null |
| owid_covid_compact.csv | `hospital_beds_per_thousand` | Derived Column | `hospital_beds_per_thousand` | 89/262 empty |
| — | — | IDENTITY | `location_id` | Surrogate key — auto-generated by SQL Server |

### dim_date

| Source | SSIS Transform | Target Column | Notes |
|---|---|---|---|
| Generated (Script Task) | None — raw date value | `date` | Sequence from 2020-01-01 to GETDATE() |
| Derived from `date` | `YEAR(date)` | `year` | |
| Derived from `date` | `MONTH(date)` | `month` | |
| Derived from `date` | `DATENAME(month, date)` | `month_name` | e.g. "March" |
| Derived from `date` | `'Q' + CAST(DATEPART(quarter, date) AS VARCHAR)` | `quarter` | e.g. "Q1" |
| Derived from `date` | `DATEPART(iso_week, date)` | `week_number` | ISO week |
| Derived from `date` | `DATENAME(weekday, date)` | `day_of_week` | e.g. "Monday" |
| Derived from `date` | `CASE WHEN DATEPART(weekday,date) IN (1,7) THEN 1 ELSE 0 END` | `is_weekend` | 1 = Sat/Sun |
| — | IDENTITY | `date_id` | Surrogate key |

### fact_covid_cases

| Source File | Source Column | SSIS Transform | Target Column | Notes |
|---|---|---|---|---|
| owid_covid_compact.csv | `date` | Data Conversion: string → DATE; then `YEAR([date])` → Derived Column | `record_year` | Partition key |
| — | Lookup on `country` → dim_location | Lookup component | `location_id` | FK |
| — | Lookup on `date` → dim_date | Lookup component | `date_id` | FK |
| owid_covid_compact.csv | `new_cases` | Data Conversion: string → FLOAT | `new_cases` | |
| owid_covid_compact.csv | `total_cases` | Data Conversion: string → FLOAT | `total_cases` | |
| owid_covid_compact.csv | `new_cases_smoothed` | Data Conversion: string → FLOAT | `new_cases_smoothed` | OWID pre-computed 7-day avg |
| owid_covid_compact.csv | `new_cases_per_million` | Data Conversion: string → FLOAT | `new_cases_per_million` | OWID pre-computed |
| owid_covid_compact.csv | `new_deaths` | Data Conversion: string → FLOAT | `new_deaths` | |
| owid_covid_compact.csv | `total_deaths` | Data Conversion: string → FLOAT | `total_deaths` | |
| owid_covid_compact.csv | `new_deaths_smoothed` | Data Conversion: string → FLOAT | `new_deaths_smoothed` | OWID pre-computed |
| owid_covid_compact.csv | `new_deaths_per_million` | Data Conversion: string → FLOAT | `new_deaths_per_million` | OWID pre-computed |
| owid_covid_compact.csv | `reproduction_rate` | Data Conversion: string → FLOAT | `reproduction_rate` | Nullable — sparse |
| owid_covid_compact.csv | `stringency_index` | Data Conversion: string → FLOAT | `stringency_index` | Nullable — sparse |
| owid_covid_compact.csv | `new_tests_smoothed` | Data Conversion: string → FLOAT | `new_tests_smoothed` | Nullable — 82% null |
| owid_covid_compact.csv | `positive_rate` | Data Conversion: string → FLOAT | `positive_rate` | Nullable — 82% null; DQ-09 rejects > 1 |
| owid_covid_compact.csv | `tests_per_case` | Data Conversion: string → FLOAT | `tests_per_case` | Nullable |

### fact_vaccination

| Source File | Source Column | SSIS Transform | Target Column | Notes |
|---|---|---|---|---|
| vaccinations_global.csv | `date` | Data Conversion: string → DATE; then `YEAR([date])` → Derived Column | `record_year` | Partition key |
| — | Lookup on `country` → dim_location | Lookup component | `location_id` | FK — name-based join, no ISO code in this file |
| — | Lookup on `date` → dim_date | Lookup component | `date_id` | FK |
| vaccinations_global.csv | `total_vaccinations` | Data Conversion: string → FLOAT | `total_vaccinations` | |
| vaccinations_global.csv | `people_vaccinated` | Data Conversion: string → FLOAT | `people_vaccinated` | |
| vaccinations_global.csv | `people_fully_vaccinated` | Data Conversion: string → FLOAT | `people_fully_vaccinated` | |
| vaccinations_global.csv | `total_boosters` | Data Conversion: string → FLOAT | `total_boosters` | Null before booster programmes |
| vaccinations_global.csv | `daily_vaccinations_smoothed` | Data Conversion: string → FLOAT | `daily_vaccinations_smoothed` | OWID pre-computed |
| vaccinations_global.csv | `people_vaccinated_per_hundred` | Data Conversion: string → FLOAT | `people_vaccinated_per_hundred` | OWID pre-computed |
| vaccinations_global.csv | `people_fully_vaccinated_per_hundred` | Data Conversion: string → FLOAT | `people_fully_vaccinated_per_hundred` | OWID pre-computed |
| vaccinations_global.csv | `total_boosters_per_hundred` | Data Conversion: string → FLOAT | `total_boosters_per_hundred` | OWID pre-computed |
| vaccinations_global.csv | `people_unvaccinated` | Data Conversion: string → FLOAT | `people_unvaccinated` | |
| vaccinations_global.csv | `rolling_vaccinations_6m` | Data Conversion: string → FLOAT | `rolling_vaccinations_6m` | OWID pre-computed |
| vaccinations_global.csv | `rolling_vaccinations_9m` | Data Conversion: string → FLOAT | `rolling_vaccinations_9m` | OWID pre-computed |
| vaccinations_global.csv | `rolling_vaccinations_12m` | Data Conversion: string → FLOAT | `rolling_vaccinations_12m` | OWID pre-computed |

### fact_hospitalization

| Source File | Source Column | SSIS Transform | Target Column | Notes |
|---|---|---|---|---|
| hospital.csv | `date` | Data Conversion: string → DATE; then `YEAR([date])` → Derived Column | `record_year` | Partition key |
| — | Lookup on `country_code` → dim_location.code | Lookup component | `location_id` | FK — ISO-3 code join (reliable) |
| — | Lookup on `date` → dim_date | Lookup component | `date_id` | FK |
| hospital.csv | `daily_occupancy_hosp` | Data Conversion: string → FLOAT | `daily_occupancy_hosp` | ~93% null |
| hospital.csv | `daily_occupancy_hosp_per_1m` | Data Conversion: string → FLOAT | `daily_occupancy_hosp_per_1m` | OWID pre-computed |
| hospital.csv | `daily_occupancy_icu` | Data Conversion: string → FLOAT | `daily_occupancy_icu` | ~93% null |
| hospital.csv | `daily_occupancy_icu_per_1m` | Data Conversion: string → FLOAT | `daily_occupancy_icu_per_1m` | OWID pre-computed |
| hospital.csv | `weekly_admissions_hosp` | Data Conversion: string → FLOAT | `weekly_admissions_hosp` | |
| hospital.csv | `weekly_admissions_hosp_per_1m` | Data Conversion: string → FLOAT | `weekly_admissions_hosp_per_1m` | OWID pre-computed |
| hospital.csv | `weekly_admissions_icu` | Data Conversion: string → FLOAT | `weekly_admissions_icu` | |
| hospital.csv | `weekly_admissions_icu_per_1m` | Data Conversion: string → FLOAT | `weekly_admissions_icu_per_1m` | OWID pre-computed |
