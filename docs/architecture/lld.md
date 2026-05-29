# Low Level Design (LLD)

## SSIS Control Flow — Overall Sequence

Shows the order in which all tasks run inside the SSIS package. Each step must succeed before the next starts. Dimensions load before facts to satisfy foreign key constraints.

```
┌──────────────────────────────────────────────────┐
│  STEP 1 — Load dim_date                          │
│  Type: Script Task                               │
│  Source: Generated (no CSV)                      │
│  Generates all dates 2020-01-01 → today          │
└───────────────────────┬──────────────────────────┘
                        │ Success
                        ▼
┌──────────────────────────────────────────────────┐
│  STEP 2 — Load dim_location                      │
│  Type: Data Flow Task                            │
│  Source: owid_covid_compact.csv                  │
│  Filter → Deduplicate → Type Cast → Load         │
└───────────────────────┬──────────────────────────┘
                        │ Success
                        ▼
┌──────────────────────────────────────────────────┐
│  STEP 3 — Truncate + Load fact_covid_cases       │
│  3a. Execute SQL Task: TRUNCATE TABLE            │
│      fact_covid_cases                            │
│  3b. Data Flow Task:                             │
│      Source: owid_covid_compact.csv              │
│      DQ Filter → Type Cast → Lookup → INSERT    │
└───────────────────────┬──────────────────────────┘
                        │ Success
                        ▼
┌──────────────────────────────────────────────────┐
│  STEP 4 — Truncate + Load fact_vaccination       │
│  4a. Execute SQL Task: TRUNCATE TABLE            │
│      fact_vaccination                            │
│  4b. Data Flow Task:                             │
│      Source: vaccinations_global.csv             │
│      DQ Filter → Type Cast → Lookup → INSERT    │
└───────────────────────┬──────────────────────────┘
                        │ Success
                        ▼
┌──────────────────────────────────────────────────┐
│  STEP 5 — Truncate + Load fact_hospitalization   │
│  5a. Execute SQL Task: TRUNCATE TABLE            │
│      fact_hospitalization                        │
│  5b. Data Flow Task:                             │
│      Source: hospital.csv                        │
│      DQ Filter → Type Cast → Lookup → INSERT    │
└───────────────────────┬──────────────────────────┘
                        │ Success
                        ▼
┌──────────────────────────────────────────────────┐
│  STEP 6 — Post-Load Verification                 │
│  Type: Execute SQL Task                          │
│  EXEC usp_verify_etl_load                        │
│  PASS → Package Complete  FAIL → Package Fails   │
└──────────────────────────────────────────────────┘
```

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
| `country` | NVARCHAR(100) | Country name |
| `code` | CHAR(3) | ISO-3 code |
| `continent` | NVARCHAR(50) | Africa, Asia, Europe, North America, Oceania, South America |
| `population` | BIGINT | |
| `population_density` | FLOAT | People per sq km |
| `median_age` | FLOAT | |
| `life_expectancy` | FLOAT | |
| `gdp_per_capita` | FLOAT | USD |
| `diabetes_prevalence` | FLOAT | % of population |
| `handwashing_facilities` | FLOAT | % with access |
| `hospital_beds_per_thousand` | FLOAT | |

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

**Step 1 — Filter (Conditional Split)**
Remove aggregate/non-country rows before anything else:

| Condition | Action |
|---|---|
| `continent IS NULL` | → reject (DQ-03) — removes "Africa", "World", "High-income countries" etc. |
| `date != MIN(date) per country` | → discard — dim_location only needs one row per country, take the first date |

**Step 2 — Deduplication**
Select DISTINCT on all country-level columns — population and metadata are the same across all dates for the same country.

**Step 3 — Column Mapping (source → target)**

| Source Column (CSV) | SSIS Component | Target Column (dim_location) | Notes |
|---|---|---|---|
| `country` | Pass-through | `country` | |
| `code` | Pass-through | `code` | ISO-3 code |
| `continent` | Pass-through | `continent` | |
| `population` | Data Conversion | `population` | float64 → BIGINT |
| `population_density` | Data Conversion | `population_density` | string → FLOAT |
| `median_age` | Data Conversion | `median_age` | string → FLOAT |
| `life_expectancy` | Data Conversion | `life_expectancy` | string → FLOAT |
| `gdp_per_capita` | Data Conversion | `gdp_per_capita` | string → FLOAT |
| `diabetes_prevalence` | Data Conversion | `diabetes_prevalence` | string → FLOAT |
| `handwashing_facilities` | Data Conversion | `handwashing_facilities` | string → FLOAT |
| `hospital_beds_per_thousand` | Data Conversion | `hospital_beds_per_thousand` | string → FLOAT |
| `location_id` | OLE DB Destination | `location_id` | IDENTITY — auto-generated by SQL Server |
| *(all other columns)* | — | *(dropped)* | date, cases, deaths etc. not needed here |

> **Cast failure handling:** Set the Data Conversion component's Error and Truncation outputs to "Redirect row" for every column. If a source value cannot be cast (e.g., `"N/A"` in `population`), the row is redirected to `dq_rejected_rows` with rule ID `DQ-CAST`. The dim_location source is stable and well-formed, so cast failures here are unexpected and should be investigated immediately.

**Step 4 — Load**
`IF NOT EXISTS` upsert by `code` — if country already exists, skip; if new, insert.

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
Truncate and reload dim_date on every run — it is always generated fresh.

---

### Data Flow 3 — fact_covid_cases
**Source:** `owid_covid_compact.csv`

**Step 1 — Row Count (Extracted) + Deduplication (Sort)**
Place a Row Count component immediately after the Flat File Source and store the count in the package variable `@[User::RowsExtracted]`. Then sort on (`country`, `date`) ascending with "Remove rows with duplicate sort values" enabled. If two rows share the same country + date, the first row in sort order is kept. A UNIQUE constraint on (`location_id`, `date_id`) in the database acts as a second-line safety net.

**Step 2 — Data Conversion (type casting)**

| Source Column | From Type | To Type |
|---|---|---|
| `date` | String | DATE |
| All numeric columns | String / float64 | FLOAT |

> **Cast failure handling:** Set Error and Truncation on every column to "Redirect row". Rows that fail any cast (e.g., `"N/A"` or `"#ERROR"` in a numeric column, or a malformed date string) are redirected to `dq_rejected_rows` with rule ID `DQ-CAST`. Data Conversion runs before the DQ Filter so that all subsequent comparisons (`date > GETDATE()`, `new_cases < 0`) operate on correctly typed values — not raw strings.

**Step 3 — Derived Column (record_year)**

| Output Column | Expression | Data Type | Purpose |
|---|---|---|---|
| `record_year` | `YEAR([date])` | `DT_I2` (2-byte signed int = SMALLINT) | Partition key — routes row to the correct year partition in SQL Server |

> This step runs after Data Conversion so `[date]` is already a typed `DATE` value. `record_year` is passed through to the OLE DB Destination alongside all other fact columns.

**Step 4 — DQ Filter (Conditional Split)**

| Condition | Action | DQ Rule |
|---|---|---|
| `date IS NULL` | → dq_rejected_rows | DQ-01 |
| `date > GETDATE()` | → dq_rejected_rows | DQ-02 |
| `continent IS NULL` | → dq_rejected_rows | DQ-03 |
| `new_cases < 0` | → dq_rejected_rows | DQ-04 |
| `new_deaths < 0` | → dq_rejected_rows | DQ-05 |
| `positive_rate > 1` | → dq_rejected_rows | DQ-09 |
| `stringency_index > 100` | → dq_rejected_rows | DQ-10 |
| All other rows | → continue to next step | |

> DQ-09 and DQ-10 are hard boundary checks on physically impossible values. They run here — after Data Conversion — so comparisons operate on typed FLOAT values. Null values in `positive_rate` and `stringency_index` pass through (null is valid; only values that exist and exceed the boundary are rejected).

**Step 5 — Lookup: resolve location_id**

| Lookup Input | Lookup Table | Match Column | Output |
|---|---|---|---|
| `country` | dim_location | `country` | `location_id` |
| No match | → dq_rejected_rows with note "country not found in dim_location" | | |

**Step 6 — Lookup: resolve date_id**

| Lookup Input | Lookup Table | Match Column | Output |
|---|---|---|---|
| `date` | dim_date | `date` | `date_id` |
| No match | → dq_rejected_rows with note "date not found in dim_date" | | |

**Step 7 — Column Mapping (source → target)**

| Source Column (CSV) | Target Column (fact_covid_cases) | Notes |
|---|---|---|
| *(derived)* | `record_year` | Partition key — from Derived Column step |
| *(lookup result)* | `location_id` | FK from dim_location |
| *(lookup result)* | `date_id` | FK from dim_date |
| `new_cases` | `new_cases` | |
| `total_cases` | `total_cases` | |
| `new_cases_smoothed` | `new_cases_smoothed` | 7-day smoothed, pre-computed by OWID |
| `new_cases_per_million` | `new_cases_per_million` | |
| `new_deaths` | `new_deaths` | |
| `total_deaths` | `total_deaths` | |
| `new_deaths_smoothed` | `new_deaths_smoothed` | |
| `new_deaths_per_million` | `new_deaths_per_million` | |
| `reproduction_rate` | `reproduction_rate` | Nullable |
| `stringency_index` | `stringency_index` | Nullable |
| `new_tests_smoothed` | `new_tests_smoothed` | Nullable (82% null) |
| `positive_rate` | `positive_rate` | Nullable (82% null) |
| `tests_per_case` | `tests_per_case` | Nullable |
| `country`, `continent`, `code` + all others | *(dropped)* | Used only for lookups and DQ, not stored in fact |

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
│   ├── 1.  Load dim_date              (Script Task — generate dates, truncate+reload)
│   ├── 2.  Load dim_location          (Data Flow — compact CSV, upsert by ISO-3)
│   ├── 3a. Truncate fact_covid_cases  (Execute SQL Task)
│   ├── 3b. Load fact_covid_cases      (Data Flow — compact CSV)
│   ├── 3c. Log run counts             (Execute SQL Task — INSERT into etl_run_log)
│   ├── 4a. Truncate fact_vaccination  (Execute SQL Task)
│   ├── 4b. Load fact_vaccination      (Data Flow — vaccinations_global.csv)
│   ├── 4c. Log run counts             (Execute SQL Task — INSERT into etl_run_log)
│   ├── 5a. Truncate fact_hosp         (Execute SQL Task)
│   ├── 5b. Load fact_hospitalization  (Data Flow — hospital.csv)
│   ├── 5c. Log run counts             (Execute SQL Task — INSERT into etl_run_log)
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
| `dim_date` | Truncate + full reload | Yes | Generated fresh every run from 2020-01-01 to today |
| `dim_location` | Upsert — INSERT if ISO-3 code not found, skip if exists | Yes | New countries added; existing countries not updated (SCD Type 1) |
| `fact_covid_cases` | Truncate + full reload | Yes | Execute SQL Task truncates before Data Flow inserts |
| `fact_vaccination` | Truncate + full reload | Yes | Execute SQL Task truncates before Data Flow inserts |
| `fact_hospitalization` | Truncate + full reload | Yes | Execute SQL Task truncates before Data Flow inserts |

**Rejection threshold:** The post-load verification (Step 6 — usp_verify_etl_load) includes a threshold check per source file. If unexpected rejects exceed 5% for fact_covid_cases or fact_hospitalization, or 10% for fact_vaccination, the procedure raises an error and fails the package. DQ-03 rejects (aggregate row removal) are excluded from the threshold — they are expected. See `docs/data-quality.md` for thresholds and the full SQL implementation.

**Late arriving data:** Because all three fact tables are truncated and fully reloaded on every run, OWID historical corrections are automatically reflected on the next package execution — no special handling required. The only exception is `dim_location` (SCD Type 1 upsert) — see `docs/data-quality.md` for the manual workaround if country metadata needs updating.

**Deduplication rule:** If the source CSV contains two rows for the same country + date, the SSIS Sort component (Step 1 of each fact flow) removes the duplicate before any DQ check or lookup runs. The first row in ascending (country, date) sort order is kept. A UNIQUE constraint on (`location_id`, `date_id`) in each fact table enforces this at the database level as a safety net — any row that bypasses the Sort step will fail at insert and be routed to `dq_rejected_rows`.

**Re-run safety:** The package can be re-run against the same CSV files without risk of duplicate rows. The truncate step on each fact table and the upsert on dim_location ensure the warehouse always reflects the current state of the source files.

**SCD Type for dim_location:** Type 1 — no history is kept. Country metadata (population, GDP, etc.) is treated as current-state only. If OWID updates a country's population figure, the existing row in dim_location is not updated unless the row is manually cleared and the package is re-run with a full reload mode. This is an accepted trade-off for a learning project.

---

## Field Lineage Summary

Single consolidated view of every field's origin — source file, source column, SSIS transform applied, and target table/column. Use this to answer "where does this column come from?" without hunting through individual flow sections.

### dim_location

| Source File | Source Column | SSIS Transform | Target Column | Notes |
|---|---|---|---|---|
| owid_covid_compact.csv | `country` | Pass-through | `country` | |
| owid_covid_compact.csv | `iso_code` | Pass-through | `code` | ISO-3 country code |
| owid_covid_compact.csv | `continent` | Pass-through | `continent` | Null rows removed by DQ-03 before reaching this table |
| owid_covid_compact.csv | `population` | Data Conversion: float64 → BIGINT | `population` | |
| owid_covid_compact.csv | `population_density` | Data Conversion: string → FLOAT | `population_density` | |
| owid_covid_compact.csv | `median_age` | Data Conversion: string → FLOAT | `median_age` | |
| owid_covid_compact.csv | `life_expectancy` | Data Conversion: string → FLOAT | `life_expectancy` | |
| owid_covid_compact.csv | `gdp_per_capita` | Data Conversion: string → FLOAT | `gdp_per_capita` | |
| owid_covid_compact.csv | `diabetes_prevalence` | Data Conversion: string → FLOAT | `diabetes_prevalence` | |
| owid_covid_compact.csv | `handwashing_facilities` | Data Conversion: string → FLOAT | `handwashing_facilities` | |
| owid_covid_compact.csv | `hospital_beds_per_thousand` | Data Conversion: string → FLOAT | `hospital_beds_per_thousand` | |
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
