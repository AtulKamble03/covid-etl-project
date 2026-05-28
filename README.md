# COVID-19 ETL Data Engineering Project

A personal learning project to build an end-to-end ETL pipeline using the Our World in Data COVID-19 dataset — using SSIS and SQL Server locally, then migrating to Snowflake.

> **Data licence:** Our World in Data COVID-19 dataset is published under
> [Creative Commons BY 4.0](https://creativecommons.org/licenses/by/4.0/).
> No patient or PHI data. Safe for personal and internal learning use.

---

## Project Phases

| Phase | Description | Status |
|-------|-------------|--------|
| 1 | Explore the dataset | In Progress |
| 2 | Design the SQL Server data warehouse (star schema) | Not Started |
| 3 | Build the SSIS ETL package | Not Started |
| 4 | Analytics and dashboard | Not Started |
| 5 | Migrate to Snowflake | Not Started |
| 6 | Scheduling and deployment (bonus) | Not Started |

---

## Tech Stack

| Tool | Purpose |
|------|---------|
| SQL Server Developer Edition | Local data warehouse |
| SSMS | Query, manage and verify loaded data |
| Visual Studio Community + SSIS extension | Design and build SSIS packages |
| SSIS (Integration Services) | ETL — extract, validate, transform, load |
| Snowflake | Cloud data warehouse (Phase 5) |

---

## Datasets

| File | Source | Size | Purpose |
|------|--------|------|---------|
| `owid_covid_compact.csv` | [OWID Compact CSV](https://catalog.ourworldindata.org/garden/covid/latest/compact/compact.csv) | ~164MB, 589k rows | Cases, deaths, country metadata |
| `hospital.csv` | [OWID Hospital](https://catalog.ourworldindata.org/garden/covid/latest/hospital/hospital.csv) | — | Hospitalization & ICU occupancy |
| `vaccinations_global.csv` | [OWID Vaccinations](https://catalog.ourworldindata.org/garden/covid/latest/vaccinations_global/vaccinations_global.csv) | — | Vaccination metrics and rolling averages |

All files go in the `data/` folder. The `data/` folder is excluded from Git — never commit raw data files.

---

## Repo Structure

```
covid-etl-project/
│
├── README.md
├── .gitignore
│
├── data/                            # Raw CSV files — NOT committed to Git
│   └── .gitkeep
│
├── docs/                            # Project documentation (source of truth)
│   ├── project-plan.md              # Phases, tech stack, business requirements
│   ├── requirements.md              # 8 business reports as Q&A
│   ├── schema-design-rationale.md   # Kimball method — requirements → schema
│   ├── data-quality.md              # 8 DQ rules + computed metrics
│   └── architecture/
│       ├── hld.md                   # High Level Design — 4-layer overview
│       └── lld.md                   # Low Level Design — tables, columns, SSIS structure
│
├── sql/
│   ├── create_tables.sql            # Phase 2 — SQL Server DDL (star schema)
│   └── analytical_queries.sql       # Phase 4 — analytics SQL for 8 reports
│
├── ssis/                            # Phase 3 — SSIS package (Visual Studio project)
│
├── etl/                             # Python scripts (Phase 1 exploration only)
│   ├── extract.py                   # Load CSV into pandas DataFrame
│   ├── transform.py                 # Clean and reshape data
│   ├── load.py                      # Write to database
│   └── pipeline.py                  # Orchestrate all steps
│
├── notebooks/
│   └── 01_explore.ipynb             # Phase 1 — dataset exploration
│
└── tests/
    └── test_transform.py            # Unit tests for transform logic
```

---

## Star Schema Design

5 tables — 2 dimensions, 3 facts. Full rationale in [docs/schema-design-rationale.md](docs/schema-design-rationale.md).

```
dim_date ──────────────────────────────────────────────┐
                                                       │
dim_location ──┬── fact_covid_cases                   │
               ├── fact_vaccination                   ─┤
               └── fact_hospitalization ───────────────┘
```

| Table | Type | Source |
|-------|------|--------|
| `dim_location` | Dimension | owid_covid_compact.csv |
| `dim_date` | Dimension | Generated |
| `fact_covid_cases` | Fact | owid_covid_compact.csv |
| `fact_vaccination` | Fact | vaccinations_global.csv |
| `fact_hospitalization` | Fact | hospital.csv |

---

## Business Reports

8 reports the warehouse is designed to answer. Full Q&A in [docs/requirements.md](docs/requirements.md).

| # | Report |
|---|--------|
| 1 | Weekly continental summary — WoW % change, hospitalizations, ICU |
| 2 | Geographic map view — cases, deaths, vaccinations by country |
| 3 | Cases over time — 7d, 28d, cumulative, most affected, vaccine impact |
| 4 | Continental aggregates — total cases per continent |
| 5 | Deaths — 7d, 28d, cumulative, CFR, trend |
| 6 | Vaccination — coverage %, supply gaps, rolling 6m/9m/12m trends |
| 7 | Hospitalization & ICU — occupancy, weekly admissions |
| 8 | Testing — total tests, positivity rate, 7d smoothed trend |

---

## Getting Started

### Prerequisites

1. [SQL Server Developer Edition](https://www.microsoft.com/en-us/sql-server/sql-server-downloads) — free
2. [SSMS](https://learn.microsoft.com/en-us/ssms/download-sql-server-management-studio-ssms) — free
3. [Visual Studio Community](https://visualstudio.microsoft.com/downloads/) + SQL Server Integration Services Projects extension — free

### Setup

1. Clone the repo
```
git clone https://github.com/AtulKamble03/covid-etl-project.git
cd covid-etl-project
```

2. Download the 3 dataset files into the `data/` folder (links in Datasets section above)

3. Open SSMS and connect to your local SQL Server instance

4. Run `sql/create_tables.sql` to create the star schema (Phase 2)

5. Open `ssis/` in Visual Studio to run the ETL package (Phase 3)

---

## Why SSIS and not Python?

SSIS is the right choice for this project because:

- **Native Microsoft stack** — fits Veradigm's SQL Server environment
- **Visual data flow designer** — drag-drop ETL in Visual Studio, no code needed for standard transforms
- **Built-in error handling** — conditional split, reject rows, error outputs without manual try/except
- **SQL Server Agent scheduling** — built-in job scheduler, no Airflow or Task Scheduler needed
- **Snowflake migration** — ODBC connector available for Phase 5 with minimal changes

Python remains the right choice for data science, Jupyter exploration, and Python-first ecosystems like Airflow and dbt.

---

## Documentation

All project documentation lives in [docs/](docs/) and is the source of truth during development. Confluence is updated at the end of each major phase.

| Doc | Purpose |
|-----|---------|
| [docs/project-plan.md](docs/project-plan.md) | Phases, tech stack, business requirements |
| [docs/requirements.md](docs/requirements.md) | 8 reports as Q&A |
| [docs/schema-design-rationale.md](docs/schema-design-rationale.md) | Why each table and column exists |
| [docs/data-quality.md](docs/data-quality.md) | DQ rules and computed metrics |
| [docs/architecture/hld.md](docs/architecture/hld.md) | High level system overview |
| [docs/architecture/lld.md](docs/architecture/lld.md) | Physical schema and SSIS package structure |
| [docs/testing.md](docs/testing.md) | 9 post-load verification checks and pass/fail template |
| [sql/verification_queries.sql](sql/verification_queries.sql) | SQL queries to run in SSMS after every ETL load |
