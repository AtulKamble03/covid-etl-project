# Business Requirements — COVID-19 Data Warehouse

## Purpose and Audience

**End consumer:** General public — anyone can view
**Goal:** Inform people about the COVID-19 situation in their area and identify where vaccination supply is needed
**Design principle:** Simple, visual, no technical jargon

**Data compliance:** This warehouse processes country-level aggregate data published by Our World in Data under Creative Commons BY 4.0. No individual-level or personal data is stored at any stage. GDPR does not apply — there are no data subjects, no PII, and no processing of personal information. Data can be used freely for personal and internal learning purposes.

## Scope

**Time period:** 2020-01-01 to 2026-05-10 (full dataset)
**Granularity:** Daily (country × day) with weekly and monthly roll-ups
**Slice by:** Country, Continent, Date, Month, Quarter

## Report 1 — Weekly Continental Summary

| # | Business Question |
|---|---|
| 1.1 | What is the week-over-week % change in new COVID-19 cases per continent? |
| 1.2 | How many new confirmed cases were reported this week per continent? |
| 1.3 | How many new hospitalizations occurred per continent this week? |
| 1.4 | How many countries reported ICU admissions this week? |

## Report 2 — Geographic Map View

| # | Business Question |
|---|---|
| 2.1 | How many total cases, deaths, and vaccinations are reported per country? |
| 2.2 | How does case density (cases per million) compare across regions and continents? |
| 2.3 | What is the demographic profile (population, GDP, median age) of each country? |

## Report 3 — Cases Over Time

| # | Business Question |
|---|---|
| 3.1 | How many new cases were reported in the last 7 days per country? |
| 3.2 | How many new cases were reported in the last 28 days per country? |
| 3.3 | What is the total cumulative case count per country? |
| 3.4 | What is the case trend for a specific country from date X to today? |
| 3.5 | Which countries were most affected by COVID-19 (by total cases and deaths)? |
| 3.6 | Did vaccination rollout reduce death rates over time? |

## Report 4 — Continental Aggregates

| # | Business Question |
|---|---|
| 4.1 | How many total COVID-19 cases have been reported per continent? |

## Report 5 — Deaths

| # | Business Question |
|---|---|
| 5.1 | How many new deaths were reported in the last 7 days per country? |
| 5.2 | How many new deaths were reported in the last 28 days per country? |
| 5.3 | What is the total cumulative death count per country and continent? |
| 5.4 | What is the weekly death trend per country? |
| 5.5 | Which countries have the highest case fatality rate (deaths / cases)? |

## Report 6 — Vaccination

| # | Business Question |
|---|---|
| 6.1 | How many people are fully vaccinated per country? |
| 6.2 | What is the vaccination coverage % per country and continent? |
| 6.3 | What is the 6-month, 9-month, 12-month rolling vaccination trend? |
| 6.4 | How many people remain unvaccinated per country? |
| 6.5 | Which countries have the lowest vaccination coverage and need supply prioritization? |
| 6.6 | What is the 7-day rolling average of vaccinations per hundred people per country? |
| 6.7 | What is the day-over-day % change in vaccinations per country? |

## Report 7 — Hospitalization and ICU

| # | Business Question |
|---|---|
| 7.1 | How many patients are currently occupying hospital beds per country? |
| 7.2 | How many patients are currently in ICU per country? |
| 7.3 | How many new hospital admissions occurred this week per country? |
| 7.4 | Which countries have the highest ICU occupancy per million? |

## Report 8 — Testing

> **Note:** Testing data is 82–87% null — coverage is limited to countries that consistently reported to OWID.

| # | Business Question |
|---|---|
| 8.1 | How many total tests have been conducted per country? |
| 8.2 | What percentage of tests came back positive per country (positivity rate)? |
| 8.3 | What is the 7-day smoothed trend of new tests per country? |
| 8.4 | Which countries have the highest positivity rate (potential under-reporting signal)? |

## Out of Scope

- Age of deaths / age of new admissions — OWID does not publish case/death data by age group
- Vaccination reactions / adverse events — not in OWID data
- WHO region groupings — using geographic continents only

---

## Report-to-Transformation Traceability

Maps each business report to the warehouse tables, source files, and ETL decisions that support it. Use this when a report requirement changes — to identify which part of the ETL or schema needs to change with it.

| Report | Tables Required | Source Files | Key ETL Decisions |
|---|---|---|---|
| **Report 1** — Weekly Continental Summary | `fact_covid_cases`, `fact_hospitalization`, `dim_date`, `dim_location` | compact CSV, hospital.csv | `week_number` derived in dim_date; `continent` from dim_location (DQ-03 ensures no aggregates); hospitalization data is ~93% null — only countries that report are included |
| **Report 2** — Geographic Map View | `fact_covid_cases`, `fact_vaccination`, `dim_location` | compact CSV, vaccinations_global.csv | `country`, `continent`, `population`, `gdp_per_capita`, `median_age` stored in dim_location; `total_cases`, `total_vaccinations` are cumulative columns from OWID — pass-through |
| **Report 3** — Cases Over Time | `fact_covid_cases`, `fact_vaccination`, `dim_date`, `dim_location` | compact CSV, vaccinations_global.csv | `new_cases_smoothed` (7-day) and `new_cases_per_million` are OWID pre-computed; 28-day and weekly totals computed at query time |
| **Report 4** — Continental Aggregates | `fact_covid_cases`, `dim_location` | compact CSV | Continental rollup is a query-time GROUP BY on `continent` — no ETL aggregation |
| **Report 5** — Deaths | `fact_covid_cases`, `dim_date`, `dim_location` | compact CSV | `new_deaths_smoothed`, `total_deaths`, `new_deaths_per_million` are OWID pre-computed; CFR computed at query time as `total_deaths / NULLIF(total_cases, 0)` |
| **Report 6** — Vaccination | `fact_vaccination`, `dim_location`, `dim_date` | vaccinations_global.csv | `rolling_vaccinations_6m/9m/12m`, `people_vaccinated_per_hundred`, `total_boosters_per_hundred` are OWID pre-computed; location joined by country name (name-match risk — 10% reject threshold applies) |
| **Report 7** — Hospitalization & ICU | `fact_hospitalization`, `dim_location`, `dim_date` | hospital.csv | All occupancy and admission columns are OWID pre-computed; ~93% null — filter `WHERE col IS NOT NULL` in queries; location joined by ISO-3 code (reliable) |
| **Report 8** — Testing | `fact_covid_cases`, `dim_location`, `dim_date` | compact CSV | `new_tests_smoothed`, `positive_rate`, `tests_per_case` are 82% null — note this in report UI; hard boundary DQ-09 rejects `positive_rate > 1` |
