# Business Requirements — COVID-19 Data Warehouse

## Purpose and Audience

**End consumer:** General public — anyone can view
**Goal:** Inform people about the COVID-19 situation in their area and identify where vaccination supply is needed
**Design principle:** Simple, visual, no technical jargon

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
