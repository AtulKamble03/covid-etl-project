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
│  STEP 3 — Load fact_covid_cases                  │
│  Type: Data Flow Task                            │
│  Source: owid_covid_compact.csv                  │
│  DQ Filter → Type Cast → Lookup → Load           │
└───────────────────────┬──────────────────────────┘
                        │ Success
                        ▼
┌──────────────────────────────────────────────────┐
│  STEP 4 — Load fact_vaccination                  │
│  Type: Data Flow Task                            │
│  Source: vaccinations_global.csv                 │
│  DQ Filter → Type Cast → Lookup → Load           │
└───────────────────────┬──────────────────────────┘
                        │ Success
                        ▼
┌──────────────────────────────────────────────────┐
│  STEP 5 — Load fact_hospitalization              │
│  Type: Data Flow Task                            │
│  Source: hospital.csv                            │
│  DQ Filter → Type Cast → Lookup → Load           │
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

**Step 1 — DQ Filter (Conditional Split)**

| Condition | Action | DQ Rule |
|---|---|---|
| `date IS NULL` | → dq_rejected_rows | DQ-01 |
| `date > today` | → dq_rejected_rows | DQ-02 |
| `continent IS NULL` | → dq_rejected_rows | DQ-03 |
| `new_cases < 0` | → dq_rejected_rows | DQ-04 |
| `new_deaths < 0` | → dq_rejected_rows | DQ-05 |
| All other rows | → continue to next step | |

**Step 2 — Data Conversion (type casting)**

| Source Column | From Type | To Type |
|---|---|---|
| `date` | String | DATE |
| All numeric columns | String / float64 | FLOAT |

**Step 3 — Lookup: resolve location_id**

| Lookup Input | Lookup Table | Match Column | Output |
|---|---|---|---|
| `country` | dim_location | `country` | `location_id` |
| No match | → dq_rejected_rows with note "country not found in dim_location" | | |

**Step 4 — Lookup: resolve date_id**

| Lookup Input | Lookup Table | Match Column | Output |
|---|---|---|---|
| `date` | dim_date | `date` | `date_id` |
| No match | → dq_rejected_rows with note "date not found in dim_date" | | |

**Step 5 — Column Mapping (source → target)**

| Source Column (CSV) | Target Column (fact_covid_cases) | Notes |
|---|---|---|
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

---

### Data Flow 4 — fact_vaccination
**Source:** `vaccinations_global.csv`

**Step 1 — DQ Filter (Conditional Split)**

| Condition | Action | DQ Rule |
|---|---|---|
| `date IS NULL` | → dq_rejected_rows | DQ-01 |
| `date > today` | → dq_rejected_rows | DQ-02 |
| All other rows | → continue | |

> Note: No continent column in this file — DQ-03 does not apply here.

**Step 2 — Data Conversion**

| Column | From | To |
|---|---|---|
| `date` | String | DATE |
| All numeric columns | String / float64 | FLOAT |

**Step 3 — Lookup: resolve location_id**

| Lookup Input | Lookup Table | Match Column | Output |
|---|---|---|---|
| `country` | dim_location | `country` | `location_id` |
| No match | → dq_rejected_rows | | |

> This file has NO ISO code — country name is the only join key. Watch for spelling differences.

**Step 4 — Lookup: resolve date_id**

| Lookup Input | Lookup Table | Match Column | Output |
|---|---|---|---|
| `date` | dim_date | `date` | `date_id` |

**Step 5 — Column Mapping (source → target)**

| Source Column (CSV) | Target Column (fact_vaccination) |
|---|---|
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

---

### Data Flow 5 — fact_hospitalization
**Source:** `hospital.csv`

**Step 1 — DQ Filter (Conditional Split)**

| Condition | Action | DQ Rule |
|---|---|---|
| `date IS NULL` | → dq_rejected_rows | DQ-01 |
| `date > today` | → dq_rejected_rows | DQ-02 |
| All other rows | → continue | |

**Step 2 — Data Conversion**

| Column | From | To |
|---|---|---|
| `date` | String | DATE |
| All numeric columns | String / float64 | FLOAT |

**Step 3 — Lookup: resolve location_id**

| Lookup Input | Lookup Table | Match Column | Output |
|---|---|---|---|
| `country_code` | dim_location | `code` | `location_id` |
| No match | → dq_rejected_rows | | |

> This file HAS an ISO-3 code (`country_code`) — use it. More reliable than country name matching.

**Step 4 — Lookup: resolve date_id**

| Lookup Input | Lookup Table | Match Column | Output |
|---|---|---|---|
| `date` | dim_date | `date` | `date_id` |

**Step 5 — Column Mapping (source → target)**

| Source Column (CSV) | Target Column (fact_hospitalization) |
|---|---|
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

---

## SSIS Package Structure

```
covid_etl.dtsx
├── Control Flow
│   ├── 1. Load dim_date (Script Task — generate dates)
│   ├── 2. Load dim_location (Data Flow — compact CSV)
│   ├── 3. Load fact_covid_cases (Data Flow — compact CSV)
│   ├── 4. Load fact_vaccination (Data Flow — vaccinations_global.csv)
│   └── 5. Load fact_hospitalization (Data Flow — hospital.csv)
│
└── Each Data Flow contains
    ├── Flat File Source (CSV)
    ├── Data Conversion (type casting)
    ├── Derived Column (computed fields)
    ├── Conditional Split (DQ rules → good rows / rejected rows)
    ├── Lookup (resolve location_id and date_id from dims)
    ├── OLE DB Destination (SQL Server target table)
    └── OLE DB Destination (dq_rejected_rows for bad rows)
```

## Join Keys Between Source Files

| Source A | Source B | Join Key |
|---|---|---|
| compact (`code`) | hospital (`country_code`) | ISO-3 code — most reliable |
| compact (`country`) | vaccinations_global (`country`) | Country name — watch for mismatches |
| All sources | dim_location | Resolved to `location_id` surrogate key in SSIS |
