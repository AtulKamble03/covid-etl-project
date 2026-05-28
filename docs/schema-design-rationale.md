# Schema Design Rationale

This document bridges business requirements and the physical schema. Every table and column is justified by at least one business question. Designed following the Kimball dimensional modelling method.

> Business questions: [docs/requirements.md](requirements.md) | Physical schema: [docs/architecture/lld.md](architecture/lld.md)

---

## Step 1 — Declare the Grain

The grain is the most important decision in dimensional modelling. It defines what one row in the fact table represents.

**Declared grain: one country × one day**

This is the finest level of detail in the source data. All roll-ups (weekly, monthly, continental) are computed at query time using SQL aggregations — they are never pre-aggregated in the warehouse.

---

## Step 2 — Map Requirements to Grain, Dimensions, and Facts

| Report | Business Question | Grain Needed | Dimensions Needed | Facts / Metrics Needed |
|---|---|---|---|---|
| R1 | WoW % change in cases per continent | Country × Day | dim_location (continent), dim_date (week) | new_cases |
| R1 | New hospitalizations per continent | Country × Day | dim_location (continent), dim_date (week) | weekly_admissions_hosp |
| R1 | Countries with ICU admissions | Country × Day | dim_location, dim_date | daily_occupancy_icu |
| R2 | Total cases, deaths, vaccinations per country on map | Country × Day | dim_location (country) | total_cases, total_deaths, total_vaccinations |
| R2 | Cases per million by continent | Country × Day | dim_location (continent) | new_cases_per_million |
| R3 | New cases last 7 days / 28 days per country | Country × Day | dim_location (country), dim_date | new_cases (windowed) |
| R3 | Most affected countries | Country × Day | dim_location (country) | total_cases, total_deaths |
| R3 | Vaccine rollout vs death rate over time | Country × Day | dim_location, dim_date | new_deaths, people_fully_vaccinated |
| R4 | Total cases per continent | Country × Day | dim_location (continent) | total_cases |
| R5 | Deaths last 7d / 28d / cumulative per country | Country × Day | dim_location (country), dim_date | new_deaths, total_deaths |
| R5 | Case fatality rate per country | Country × Day | dim_location (country) | total_deaths / total_cases |
| R6 | Vaccination coverage % per country | Country × Day | dim_location (country) | people_fully_vaccinated_per_hundred |
| R6 | Countries needing vaccination supply | Country × Day | dim_location (country, continent) | people_unvaccinated |
| R6 | 7-day rolling avg vaccinations per hundred | Country × Day | dim_location, dim_date | daily_vaccinations_smoothed |
| R6 | 6m / 9m / 12m rolling vaccination trends | Country × Day | dim_location, dim_date | rolling_vaccinations_6m/9m/12m |
| R7 | Hospital / ICU occupancy per country | Country × Day | dim_location (country), dim_date | daily_occupancy_hosp, daily_occupancy_icu |
| R7 | Weekly hospital admissions | Country × Day | dim_location, dim_date (week) | weekly_admissions_hosp, weekly_admissions_icu |
| R7 | Highest ICU per million | Country × Day | dim_location (country) | daily_occupancy_icu_per_1m |
| R8 | Total tests per country | Country × Day | dim_location (country) | total_tests |
| R8 | Positivity rate per country | Country × Day | dim_location (country), dim_date | positive_rate |
| R8 | 7-day smoothed new tests | Country × Day | dim_location, dim_date | new_tests_smoothed |

---

## Step 3 — Derive Dimensions from Requirements

Taking the union of all "Dimensions Needed" above:

| Dimension | Required By | Columns Justified |
|---|---|---|
| **dim_location** | All 8 reports | `country` (R2, R3, R5, R6, R7, R8), `continent` (R1, R2, R4, R6), `code` (join key to hospital.csv), `population` (per-million calculations), `gdp_per_capita`, `median_age`, `hospital_beds_per_thousand` (country profile for R2 map view) |
| **dim_date** | R1, R3, R5, R6, R7, R8 | `date` (all), `week_number` (R1 WoW %), `month` (monthly roll-ups), `quarter` (quarterly slice), `year` (annual trend), `day_of_week`, `is_weekend` |

---

## Step 4 — Derive Fact Tables from Requirements

Three distinct source files with different grains and subjects → three fact tables.

### fact_covid_cases
**Justified by:** Reports 1, 2, 3, 4, 5, 8
**Source:** `owid_covid_compact.csv`

| Column | Justified By |
|---|---|
| `new_cases` | R1 (WoW %), R3 (7d/28d), R4 (continental totals) |
| `total_cases` | R2 (map), R3 (most affected), R4 (continental) |
| `new_cases_smoothed` | R3 (trend lines) |
| `new_cases_per_million` | R2 (density comparison) |
| `new_deaths` | R5 (7d/28d deaths) |
| `total_deaths` | R2 (map), R3 (vaccine impact), R5 (cumulative, CFR) |
| `new_deaths_smoothed` | R5 (trend lines) |
| `new_deaths_per_million` | R5 (country comparison) |
| `reproduction_rate` | R3 (spread trend) |
| `stringency_index` | R3 (policy context alongside vaccine impact) |
| `new_tests_smoothed` | R8 (7d test trend) |
| `positive_rate` | R8 (positivity rate) |
| `tests_per_case` | R8 (under-reporting signal) |

### fact_vaccination
**Justified by:** Report 3 (vaccine vs deaths), Report 6
**Source:** `vaccinations_global.csv`

| Column | Justified By |
|---|---|
| `total_vaccinations` | R6 (coverage) |
| `people_vaccinated` | R6 (coverage %) |
| `people_fully_vaccinated` | R3 (vaccine impact), R6 (coverage %) |
| `people_fully_vaccinated_per_hundred` | R6 (coverage % per country) |
| `total_boosters` | R6 (booster coverage) |
| `daily_vaccinations_smoothed` | R6 (7-day rolling avg) |
| `people_unvaccinated` | R6 (supply prioritization) |
| `rolling_vaccinations_6m/9m/12m` | R6 (rolling trends) |

### fact_hospitalization
**Justified by:** Reports 1, 7
**Source:** `hospital.csv`

| Column | Justified By |
|---|---|
| `daily_occupancy_hosp` | R7 (hospital occupancy) |
| `daily_occupancy_hosp_per_1m` | R7 (country comparison) |
| `daily_occupancy_icu` | R1 (ICU country count), R7 (ICU occupancy) |
| `daily_occupancy_icu_per_1m` | R7 (highest ICU per million) |
| `weekly_admissions_hosp` | R1 (weekly hospitalizations), R7 |
| `weekly_admissions_hosp_per_1m` | R7 |
| `weekly_admissions_icu` | R1, R7 |
| `weekly_admissions_icu_per_1m` | R7 |

---

## Step 5 — Final Schema (derived from requirements)

```
dim_date ──────────────────────────────────────────────┐
(date_id PK)                                           │
                                                       │
dim_location ──┬── fact_covid_cases (R1,2,3,4,5,8)   │
(location_id   │      location_id FK                  ┤
 PK)           │      date_id FK                      │
               │                                       │
               ├── fact_vaccination (R3,6)             │
               │      location_id FK                  ┤
               │      date_id FK                      │
               │                                       │
               └── fact_hospitalization (R1,7)         │
                      location_id FK                  ┤
                      date_id FK ─────────────────────┘
```

---

## Design Decisions

| Decision | Reason |
|---|---|
| 3 fact tables instead of 1 | Three source files have different coverage — hospital data is 93% null in compact CSV. Merging into one fact table would waste storage and complicate nullability. |
| Grain is country × day, not continent × week | Finest grain gives maximum flexibility. Continental and weekly views are computed at query time — no pre-aggregation needed. |
| dim_location sourced from compact CSV only | Compact has the richest country metadata (population, GDP, median age). Hospital and vaccination files are joined to it via ISO code or country name. |
| dim_date generated, not sourced from CSV | Ensures no gaps in the date dimension even if source data has missing dates. |
| Surrogate keys on all dimensions | Insulates fact tables from natural key changes. ISO codes and country names can change — surrogate keys never do. |
| No WHO region column | Removed from scope — geographic continents from compact CSV are sufficient for all 8 reports. |
