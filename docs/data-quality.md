# Data Quality Rules

## Validation Rules (applied in SSIS before load)

| # | Rule | Column(s) | Action if Violated |
|---|---|---|---|
| DQ-01 | `date` must not be null | `date` | Reject row entirely |
| DQ-02 | `date` must not be in the future | `date` | Reject row entirely |
| DQ-03 | `continent` must not be null | `continent` | Reject row — removes all aggregate/non-country rows automatically |
| DQ-04 | `new_cases` must not be negative | `new_cases` | Flag row → load to reject table |
| DQ-05 | `new_deaths` must not be negative | `new_deaths` | Flag row → load to reject table |
| DQ-06 | `total_cases` must never decrease day over day | `total_cases` | Flag as anomaly, log warning |
| DQ-07 | `total_deaths` must never decrease day over day | `total_deaths` | Flag as anomaly, log warning |
| DQ-08 | `total_vaccinations` must never decrease day over day | `total_vaccinations` | Flag as anomaly, log warning |

## Reject Table

Rows that fail DQ-01 through DQ-05 are written to a `dq_rejected_rows` table with:
- Original row data
- Rule ID that was violated (DQ-01 to DQ-05)
- Source file name
- Load timestamp

## Computed / Derived Metrics

| Metric | Calculation |
|---|---|
| 7-day rolling average new cases | `AVG(new_cases) OVER (PARTITION BY country ORDER BY date ROWS 6 PRECEDING)` |
| 7-day rolling average vaccinations per hundred | `AVG(new_vaccinations_smoothed_per_million) OVER (PARTITION BY country ORDER BY date ROWS 6 PRECEDING)` |
| Day-over-day % change | `(today - yesterday) / NULLIF(yesterday, 0) * 100` |
| 28-day case total | `SUM(new_cases) OVER (PARTITION BY country ORDER BY date ROWS 27 PRECEDING)` |
| Weekly aggregates | `SUM(new_cases)` grouped by `week_number + year` |
| Monthly aggregates | `SUM(new_cases)` grouped by `month + year` |
