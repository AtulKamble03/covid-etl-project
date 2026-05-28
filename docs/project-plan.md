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

## Datasets

| File | Purpose | Null Risk |
|---|---|---|
| `owid_covid_compact.csv` | Core cases, deaths, country metadata | Low (cases/deaths ~3% null) |
| `hospital.csv` | Hospitalization & ICU daily occupancy and admissions | Medium |
| `vaccinations_global.csv` | Full vaccination metrics including rolling averages | Medium |

**Data source:** [Our World in Data — COVID-19](https://ourworldindata.org/covid-deaths)
**License:** Creative Commons BY 4.0 — safe for personal and corporate learning with attribution.

## Tech Stack

| Tool | Purpose | Cost |
|---|---|---|
| SQL Server Developer Edition | Local data warehouse | Free |
| SSMS | Query, manage, verify loaded data | Free |
| Visual Studio Community + SSIS extension | Design and build SSIS packages | Free |
| SSIS (Integration Services) | ETL — extract, transform, load | Free (included with SQL Server) |
| Snowflake | Cloud data warehouse (Phase 5) | Free trial ($400 credits) |
| Azure (optional) | Cloud deployment | $200 credits |

## Business Requirements

> Full Q&A detail: [docs/requirements.md](requirements.md) | Schema rationale: [docs/schema-design-rationale.md](schema-design-rationale.md)

**Audience:** General public — anyone can view to understand COVID-19 situation in their area and where vaccination supply is needed.

**Granularity:** Daily (country × day) with weekly and monthly roll-ups.
**Slice by:** Country, Continent, Date, Month, Quarter.
**Time period:** 2020-01-01 to 2026-05-10.

### Report 1 — Weekly Continental Summary
- Q: What is the week-over-week % change in new cases per continent?
- Q: How many new hospitalizations occurred per continent this week?
- Q: How many countries reported ICU admissions this week?

### Report 2 — Geographic Map View
- Q: How many total cases, deaths, and vaccinations per country?
- Q: How does case density (cases per million) compare across continents?

### Report 3 — Cases Over Time
- Q: How many new cases in the last 7 days / 28 days per country?
- Q: What is the total cumulative case count per country?
- Q: Which countries were most affected by COVID-19?
- Q: Did vaccination rollout reduce death rates over time?

### Report 4 — Continental Aggregates
- Q: How many total COVID-19 cases have been reported per continent?

### Report 5 — Deaths
- Q: How many new deaths in the last 7 days / 28 days per country?
- Q: What is the total cumulative death count per country and continent?
- Q: Which countries have the highest case fatality rate?

### Report 6 — Vaccination
- Q: What is the vaccination coverage % per country and continent?
- Q: Which countries need vaccination supply prioritization?
- Q: What is the 7-day rolling average of vaccinations per hundred people?
- Q: What are the 6-month, 9-month, 12-month rolling vaccination trends?

### Report 7 — Hospitalization and ICU
- Q: How many patients are currently in hospital / ICU per country?
- Q: How many new hospital admissions occurred this week?
- Q: Which countries have the highest ICU occupancy per million?

### Report 8 — Testing
- Q: How many total tests have been conducted per country?
- Q: What is the positivity rate (% of tests positive) per country?
- Q: Which countries have the highest positivity rate?

## Project Phases

### Phase 1 — Explore the Dataset
**Status: In Progress**

- [x] Download dataset CSVs (compact, hospital, vaccinations_global)
- [ ] Analyze owid_covid_compact.csv — columns, nulls, date range, countries
- [ ] Identify data quality issues: nulls, aggregate rows, negative values
- [ ] Document key columns and data types

### Phase 2 — Design the Data Warehouse
**Status: Not Started**

Design a star schema with 3 fact tables and 2 dimension tables.

- [ ] Finalize table definitions and SQL Server data types
- [ ] Write CREATE TABLE scripts for SQL Server
- [ ] Create tables in local SQL Server via SSMS
- [ ] Validate schema with sample data

### Phase 3 — Build the SSIS ETL Package
**Status: Not Started**

- [ ] Create SSIS project in Visual Studio
- [ ] Build data flow: compact CSV → dim_location + fact_covid_cases
- [ ] Build data flow: vaccinations_global.csv → fact_vaccination
- [ ] Build data flow: hospital.csv → fact_hospitalization
- [ ] Build dim_date (generate date dimension)
- [ ] Implement data quality rules (reject table, error logging)
- [ ] Test full package end-to-end

### Phase 4 — Analytics and Dashboard
**Status: Not Started**

- [ ] Write SQL queries for all 8 reports
- [ ] Build computed metrics (7-day rolling avg, WoW % change, 28-day totals)
- [ ] Create visualization (Power BI or SSRS)

### Phase 5 — Migrate to Snowflake
**Status: Not Started**

- [ ] Sign up for Snowflake free trial
- [ ] Recreate schema in Snowflake
- [ ] Migrate SSIS load targets to Snowflake (ODBC connector)
- [ ] Validate data loaded correctly
- [ ] Run same analytical queries in Snowflake

### Phase 6 — Schedule and Deploy (Bonus)
**Status: Not Started**

- [ ] Schedule SSIS package via SQL Server Agent
- [ ] Add pre-load data validation
- [ ] (Optional) Deploy to Azure

## Skills You Will Learn

| Skill | Phase |
|---|---|
| SQL Server schema design (star schema, Kimball) | Phase 2 |
| SSIS package development | Phase 3 |
| Data quality and rejection handling | Phase 3 |
| ETL pipeline design | Phase 3 |
| Analytical SQL (window functions, rolling avg) | Phase 4 |
| Power BI / SSRS reporting | Phase 4 |
| Snowflake cloud data warehouse | Phase 5 |
| Pipeline scheduling (SQL Server Agent) | Phase 6 |
