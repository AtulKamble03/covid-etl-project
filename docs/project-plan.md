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
