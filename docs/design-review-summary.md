# Design Review Summary — Plain English

**What this document is:** A non-technical summary of what this project does, what gaps we found in the original design, what we fixed, and what the project looks like now. Written so anyone — technical or not — can follow along.

---

## 1. What This Project Does (In Simple Terms)

Imagine you have three large spreadsheets full of COVID-19 data — one with daily case and death numbers for every country, one with vaccination numbers, and one with hospital occupancy numbers. Each spreadsheet has hundreds of thousands of rows.

The goal of this project is to:
1. **Clean** those spreadsheets — remove bad rows, fix data types, fill gaps
2. **Organise** the cleaned data into a proper database — so it can be queried quickly
3. **Answer** eight specific questions (business reports) — like "which countries had the highest death rates?" or "which countries still need vaccines?"

The tool that does steps 1 and 2 is called **SSIS** — think of it as an automated assembly line. Raw data goes in one end, cleaned and organised data comes out the other end into SQL Server (a database).

---

## 2. What We Were Reviewing

Before building the assembly line, we had design documents — a **High Level Design (HLD)** describing the big picture, and a **Low Level Design (LLD)** describing the step-by-step detail.

We reviewed those documents against a checklist of things every good ETL (data pipeline) design should cover. The checklist had eight categories:

| Category | Simple Question |
|---|---|
| Business rules | Do we know what transformations to apply and why? |
| Data consumer | Do we know who uses the data and for what? |
| Transformation logic | Have we designed every step of the assembly line? |
| Data quality | What do we do when the data is bad? |
| Performance | Will it run fast enough? |
| Error handling | What happens when something goes wrong? |
| Data lineage | Can we trace every output column back to its source? |
| Idempotency | Can we safely re-run the pipeline without breaking things? |

We found **15 gaps** — things that were missing or unclear. We fixed all 15.

---

## 3. The 15 Things We Fixed (With Simple Examples)

### Gap 1 & 2 — We did not say how the fact tables get loaded (Critical)

**The problem:** The design said "load the data" but never said *how*. Does it add new rows on top of old ones each time? Does it clear everything first? If you run the pipeline twice, do you end up with duplicate data?

**The analogy:** Imagine a whiteboard with today's scores written on it. When tomorrow comes, do you *erase* the board and write fresh scores? Or do you *add* tomorrow's scores underneath today's? If you add without erasing and run it twice, you'd have two copies of the same day.

**What we fixed:** We defined that all three data tables (cases, vaccinations, hospitalisations) are **cleared first, then reloaded fresh** every time the pipeline runs. Like erasing the whiteboard before writing. This makes it safe to re-run without getting duplicates.

---

### Gap 3 — We had no rule for duplicate rows in the source data (Critical)

**The problem:** The source spreadsheet might occasionally have the same country + same date appearing twice. We had no instruction for what to do in that situation — both rows could have ended up in the database.

**The analogy:** If a teacher's register has "Alice Smith — 15 Jan" written twice, which one counts? We needed a rule.

**What we fixed:** We added a **sort step** at the start of each flow. The data is sorted by country and date, and if two rows are identical on those two values, the first one is kept and the second is discarded. We also added a database-level rule (UNIQUE constraint) so the database itself would reject any second copy that somehow slipped through.

---

### Gap 4 — No plan for when a data type conversion fails (Critical)

**The problem:** The data comes in as text (strings). We convert it to proper types — dates become date values, numbers become numbers. But what if the source file sends something unexpected, like "N/A" or "#ERROR" in a number column? The conversion would crash.

**The analogy:** Imagine a form where someone writes "banana" in the "Age" field. Your system tries to treat it as a number and breaks.

**What we fixed:** We configured the conversion step to **redirect bad rows** to a separate "reject" table instead of crashing. The bad row gets logged with a reason code (DQ-CAST) so it can be investigated later. We also corrected the order of steps — conversion now happens *before* the quality checks, because quality checks like "is this date in the future?" only work correctly on a proper date value, not a text string.

---

### Gap 5 — No clear policy on NULL values across all columns (High)

**The problem:** NULL means a cell is empty. The design only talked about two specific null checks (date and continent). It said nothing about the other 30+ columns. Were nulls allowed? Should they be replaced with zero?

**The analogy:** In a school register, a blank cell means "absent" — it is very different from a zero. If you replace every blank with a zero, you'd be saying everyone scored zero, which is wrong.

**What we fixed:** We documented a clear rule for every single column: **NULL means "not reported" and is never replaced with zero.** A country with NULL in new_cases simply didn't report that day — that is different from reporting zero cases. We also flagged two columns that are expected to be mostly null (test data is 82% blank, hospitalisation data is 93% blank) — so analysts know this is normal, not an error.

---

### Gap 6 — No strategy for data that arrives late (High)

**The problem:** The data publisher (Our World in Data / OWID) sometimes goes back and corrects old numbers — for example, they might update a country's case count from three months ago. What happens if we've already loaded those old numbers?

**The analogy:** Imagine a newspaper that prints a correction the next day. If you keep the old newspaper on file without replacing it, your records are wrong. If you throw away the old one and file the new one, your records are correct.

**What we fixed:** Because our pipeline already **clears and reloads everything** each time it runs (from Gap 1), historical corrections are automatically picked up on the next run. No special action is needed. We documented this explicitly, along with the one exception — country reference data (population, GDP, etc.) uses a different loading method and needs a manual step if those values are corrected.

---

### Gap 7 — No rule for when too many rows are rejected (High)

**The problem:** If the pipeline runs and rejects 80% of the data due to bad quality, it would still mark itself as "successful" — because there was no threshold that triggers a failure.

**The analogy:** A juice factory's quality inspector checks every bottle. But if the policy is "keep going no matter how many bad bottles we find," you'd end up shipping 80% bad juice with a "passed" label.

**What we fixed:** We added **rejection thresholds** per data source:
- Cases data (owid_covid_compact.csv): if more than **5%** of rows are unexpectedly rejected → pipeline fails
- Vaccination data: if more than **10%** are rejected → pipeline fails (slightly higher because the country-name matching is less precise)
- Hospitalisation data: if more than **5%** are rejected → pipeline fails

If a threshold is breached, the pipeline stops, logs the failure, and does not mark itself as complete. Analysts know not to use the data until the problem is investigated and the pipeline re-run successfully.

---

### Gap 8 — No tracking of how many rows went in vs came out (High)

**The problem:** There was no record of how many rows the pipeline read from each file, how many it loaded, and how many it rejected. Without this, you can't compare yesterday's run to today's or spot if something went quietly wrong.

**The analogy:** A factory tracks how many raw materials went in and how many finished products came out. If 1,000 bolts went in but only 700 came out and 50 were scrapped, what happened to the other 250? You need to know.

**What we fixed:** We added counters (Row Count components in SSIS) at three points in each flow:
- **Rows extracted** — how many the pipeline read from the file
- **Rows loaded** — how many made it into the database
- **Rows rejected** — how many went to the reject table

These three numbers are written to a log table (`etl_run_log`) after every run. If `extracted ≠ loaded + rejected`, something was silently lost — which is an immediate red flag.

---

### Gap 9 — No check for physically impossible values (Medium)

**The problem:** The quality checks (DQ rules) only looked for null dates, future dates, negative case counts, and negative death counts. They didn't check for values that are mathematically impossible.

**The analogy:** A temperature sensor reading -300°C would pass a "is it a valid number?" check — but it's physically impossible because absolute zero is -273°C. You need a separate check for "is it a possible number?"

**What we fixed:** We added two hard-boundary checks:
- **Positivity rate > 100%** — impossible. If 120 out of 100 tests came back positive, the data is wrong.
- **Stringency index > 100** — impossible. This index is defined on a 0-to-100 scale.

Rows that violate these are rejected and logged with reason codes DQ-09 and DQ-10.

We also added four **soft warning checks** that run after loading — they flag unusual values for human review without stopping the pipeline:
- A single country reporting more than 1 million new cases in one day (could be a backlog correction dump — valid, but worth checking)
- A reproduction rate above 15 (no disease in history has had this)
- "Fully vaccinated" count being higher than "vaccinated" count (logically impossible)
- A country's single-day case count exceeding its entire population (physically impossible)

---

### Gap 10, 11, 12 — Three design decisions never written down (Medium)

**Gap 10 — Aggregation decision:**
The pipeline never adds up or groups data. All totals, weekly summaries, and regional averages are calculated at the time of reporting — not during loading. This was the right choice but was never stated. We documented it explicitly so no one adds an unnecessary summarisation step during implementation.

**Gap 11 — Pre-calculated columns from the source:**
Several columns in the database (7-day smoothed averages, per-million rates, per-hundred percentages) are not calculated by our pipeline — they come pre-calculated from OWID and are passed through as-is. This was never documented. We listed every such column clearly so implementers know not to add formulas for them.

**Gap 12 — Partitioning (filing cabinet strategy):**

**The problem:** As the database grows, queries that only need one year's data still had to scan the entire table.

**The analogy:** Imagine a filing cabinet with five years of invoices all mixed together. Finding all invoices from 2022 means leafing through everything. But if you have a tab divider for each year, you go straight to the 2022 section.

**What we fixed:** We split all three fact tables into **yearly partitions** — one section per year (2020, 2021, 2022, 2023, 2024, 2025, 2026+). A query asking "show me 2022 cases" now only looks in the 2022 section and skips the rest. We also added a `record_year` column to each row (populated automatically by the pipeline from the date column) so SQL Server knows which partition each row belongs to.

---

### Gap 13 — No regulatory compliance statement (Low)

**What we fixed:** Added a clear one-liner to the requirements document: this project uses country-level aggregate data (no names, no individual records, no personal information). GDPR does not apply. The data is published under a Creative Commons open licence.

---

### Gap 14 — No link between business questions and technical design (Low)

**The problem:** The eight business reports and the database design were in separate documents with no connection between them. A reader couldn't tell which database columns support which report.

**What we fixed:** Added a **traceability table** in the requirements document. Each of the eight reports now shows which tables it needs, which source files feed it, and which ETL decisions affect it. If a report requirement changes, you can immediately see what in the pipeline needs to change.

---

### Gap 15 — Lineage was scattered across 5 separate sections (Low)

**The problem:** If you wanted to know "where does the `people_fully_vaccinated` column come from?", you had to hunt through five different data flow sections in the LLD.

**What we fixed:** Added a **consolidated lineage table** at the end of the LLD. It shows every single column in the database in one place — source file, source column name, what transformation was applied, and target column. 40+ columns, one table per database table, all in one section.

---

## 4. What Each Document Looks Like Now

| Document | What It Contains |
|---|---|
| `docs/architecture/hld.md` | Big picture — four-layer diagram (source → ETL → storage → analytics), updated with explicit design principles including idempotency and the no-aggregation decision |
| `docs/architecture/lld.md` | Detailed step-by-step design for every data flow, correct step ordering, dedup rules, cast failure handling, null policy notes, partitioning design, SSIS component list, and the consolidated field lineage at the end |
| `docs/data-quality.md` | All quality rules in one place — step order, 10 validation rules (DQ-CAST through DQ-10), null policy per column for all 40+ fields, late arriving data strategy, rejection thresholds with SQL, row count logging, outlier detection (hard boundaries + soft warnings), and a clear split between OWID pre-computed values vs query-time calculated values |
| `docs/requirements.md` | Eight business reports as questions, GDPR compliance statement, and a traceability table linking each report to its tables, source files, and ETL decisions |
| `docs/testing.md` | Nine post-load verification checks (unchanged) |
| `sql/create_tables.sql` | Full SQL Server DDL — all five tables, partition function, partition scheme, clustered and non-clustered indexes, DQ reject table, ETL run log table. Rewritten from scratch (the original was PostgreSQL syntax — now correct SQL Server syntax) |
| `sql/usp_verify_etl_load.sql` | Stored procedure with 11 checks — original 9 preserved, plus CHECK 10 (rejection threshold per source file) and CHECK 11 (soft outlier detection) |

---

## 5. What Stays the Same

The following did not change — they were already well designed:

- The star schema (2 dimensions, 3 fact tables) — sound Kimball design
- The eight business reports — requirements are clear and complete
- The DQ reject table concept — good from the start
- The post-load verification idea — nine checks are comprehensive
- The decision to use SSIS over Python — right tool for this environment
- The data source (OWID COVID-19 dataset) — well-maintained, openly licensed

---

## 6. What Comes Next (Phases Not Yet Started)

| Phase | What Happens |
|---|---|
| Phase 2 | Run `sql/create_tables.sql` in SSMS to create the database |
| Phase 3 | Build the SSIS package in Visual Studio, following the LLD step by step |
| Phase 4 | Write analytical queries and connect Power BI or SSRS for the 8 reports |
| Phase 5 | Migrate to Snowflake using an ODBC connector |
| Phase 6 | Schedule the pipeline to run daily using SQL Server Agent |
