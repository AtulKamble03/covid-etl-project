# Low Level Design (LLD)

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
