# COVID-19 ETL Data Engineering Project

A personal learning project to build an end-to-end ETL pipeline using the
Our World in Data COVID-19 dataset — progressing from local PostgreSQL to
Snowflake cloud warehouse.

> **Data licence:** Our World in Data COVID-19 dataset is published under
> [Creative Commons BY 4.0](https://creativecommons.org/licenses/by/4.0/).
> No patient or PHI data. Safe for personal and internal learning use.

---

## Project phases

| Phase | Description | Status |
|-------|-------------|--------|
| 1 | Explore the dataset | In Progress |
| 2 | Design the data warehouse (star schema) | Not Started |
| 3 | Build the ETL pipeline | Not Started |
| 4 | Analytics and dashboard | Not Started |
| 5 | Migrate to Snowflake | Not Started |
| 6 | Scheduling and deployment (bonus) | Not Started |

---

## Tech stack

| Tool | Purpose |
|------|---------|
| Python 3.11+ | ETL scripting |
| pandas | Data extraction and transformation |
| PostgreSQL (local) | Local data warehouse |
| SQLAlchemy + psycopg2 | Python → PostgreSQL connector |
| Snowflake | Cloud data warehouse (Phase 5) |
| Jupyter Notebook | Interactive data exploration (Phase 1) |
| VS Code | Primary IDE |

---

## Repo structure

```
covid-etl-project/
│
├── README.md
├── requirements.txt
├── .gitignore
│
├── data/                        # Raw data — NOT committed to Git
│   └── .gitkeep
│
├── notebooks/
│   └── 01_explore.ipynb         # Phase 1 — dataset exploration
│
├── etl/
│   ├── __init__.py
│   ├── extract.py               # Phase 3 — download and read CSV
│   ├── transform.py             # Phase 3 — clean and reshape data
│   ├── load.py                  # Phase 3 — write to warehouse
│   └── pipeline.py              # Phase 3 — orchestrate all three steps
│
├── sql/
│   ├── create_tables.sql        # Phase 2 — star schema DDL
│   └── analytical_queries.sql  # Phase 4 — analytics SQL
│
├── config/
│   ├── db_config.py             # NOT committed — add your credentials here
│   └── db_config_example.py    # Safe template — committed as reference
│
└── tests/
    └── test_transform.py        # Basic unit tests for transform logic
```

---

## Getting started

### 1. Clone the repo

```bash
git clone https://github.com/<your-username>/covid-etl-project.git
cd covid-etl-project
```

### 2. Create a virtual environment

```bash
python -m venv venv
# Windows
venv\Scripts\activate
# Mac / Linux
source venv/bin/activate
```

### 3. Install dependencies

```bash
pip install -r requirements.txt
```

### 4. Set up your database config

```bash
cp config/db_config_example.py config/db_config.py
# Edit db_config.py with your PostgreSQL credentials
```

### 5. Start with Phase 1

Open `notebooks/01_explore.ipynb` in VS Code or Jupyter and run the cells.

---

## Why Python and not C#?

Python is the native language of data engineering. Key reasons for this project:

- **pandas** makes data transformation 5x less code than C# equivalents
- **Jupyter Notebooks** enable interactive exploration — no C# equivalent
- **Snowflake, Airflow, dbt** are all Python-first tools
- Swapping from PostgreSQL to Snowflake requires changing one import line
- Industry standard — expected skill for all data engineering roles

C# remains the right choice for production APIs and .NET enterprise apps.

---

## Dataset

- **Source:** [Our World in Data — COVID-19](https://ourworldindata.org/covid-deaths)
- **Direct CSV:** https://covid.ourworldindata.org/data/owid-covid-data.csv
- **Licence:** Creative Commons BY 4.0
- **Content:** Daily cases, deaths, vaccinations for 200+ countries from 2020–2023
- **Size:** ~90MB, ~300,000 rows
