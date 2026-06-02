# Learning Plan — Transactional Databases, Normalization & Database Migration

**Owner:** Atul Kamble
**Goal:** Deeply understand OLTP systems, normalization, OLTP vs OLAP differences,
data sync between transaction databases, and DB migration strategies.
**Format:** Theory + real-world analogies + hands-on SQL project

---

## Why This Matters (Context)

At Veradigm, the clinical data you work with starts life in **transactional databases**
(EHR systems, lab systems, pharmacy systems) before it reaches the data warehouse.
Understanding how those source systems are built is essential for designing good ETL
pipelines — you need to know where the data comes from and why it's structured the way it is.

---

## The Big Picture — OLTP vs OLAP

| | OLTP (Transactional) | OLAP (Data Warehouse — what we built) |
|---|---|---|
| **Purpose** | Record daily operations | Analyse historical data |
| **Query type** | Short, frequent, precise (1 row) | Long, aggregated (millions of rows) |
| **Schema** | Highly normalised (3NF+) | Denormalised (star schema) |
| **Users** | Clerks, nurses, doctors (thousands) | Analysts, executives (tens) |
| **Write pattern** | Constant INSERT/UPDATE/DELETE | Batch load (nightly/hourly) |
| **Data volume** | Current data (GB) | Historical data (TB) |
| **Example** | Hospital EHR, bank transactions | COVID-19 warehouse we built |

**Analogy:** OLTP is a restaurant's kitchen — fast, real-time, processing one order
at a time. OLAP is the restaurant's monthly financial review — looking at everything
that happened and finding patterns.

---

## Phase 1 — Normalisation Deep Dive
**Goal:** Understand why OLTP databases are structured differently from warehouses

### 1.1 Why Normalise?

**Problem without normalisation:**
```
PatientID | PatientName | DoctorID | DoctorName | DoctorPhone | DiagnosisCode | DiagnosisName
1001      | John Smith  | D01      | Dr. Adams  | 555-1234    | J06.9         | Cold
1001      | John Smith  | D01      | Dr. Adams  | 555-1234    | K21.0         | Acid Reflux
1002      | Mary Jones  | D01      | Dr. Adams  | 555-1234    | J06.9         | Cold
```

Problems:
- Dr. Adams' phone appears 3 times → change it in 3 places (update anomaly)
- Delete the last patient → lose Dr. Adams' record (delete anomaly)
- Can't add a new doctor without a patient (insert anomaly)

**This is exactly what normalisation solves.**

---

### 1.2 First Normal Form (1NF)
**Rule:** Each column must contain atomic (indivisible) values. No repeating groups.

**Violation:**
```
PatientID | Name       | Diagnoses
1001      | John Smith | Cold, Acid Reflux, Hypertension
```

**Fixed:**
```
PatientID | Name       | DiagnosisCode
1001      | John Smith | J06.9
1001      | John Smith | K21.0
1001      | John Smith | I10
```

**Real-world analogy:** A hospital form that has "Medications 1, 2, 3" columns
violates 1NF. A separate medications table (one row per medication) is 1NF.

---

### 1.3 Second Normal Form (2NF)
**Rule:** Must be 1NF + every non-key column depends on the WHOLE primary key
(eliminates partial dependencies — only relevant when PK is composite).

**Violation (composite PK = PatientID + VisitID):**
```
PatientID | VisitID | PatientName | VisitDate  | Diagnosis
1001      | V001    | John Smith  | 2024-01-15 | Cold
```
Problem: `PatientName` depends only on `PatientID`, not on `(PatientID + VisitID)`.

**Fixed:**
```
-- Patient table
PatientID | PatientName
1001      | John Smith

-- Visit table
PatientID | VisitID | VisitDate  | Diagnosis
1001      | V001    | 2024-01-15 | Cold
```

---

### 1.4 Third Normal Form (3NF) — Most Important
**Rule:** Must be 2NF + no transitive dependencies (non-key columns don't depend on other non-key columns).

**Violation:**
```
PatientID | ZipCode | City       | State
1001      | 60601   | Chicago    | IL
```
Problem: `City` and `State` depend on `ZipCode`, not on `PatientID`.

**Fixed:**
```
-- Patient
PatientID | ZipCode
1001      | 60601

-- ZipCode reference
ZipCode | City    | State
60601   | Chicago | IL
```

**Real-world analogy:** This is why every system has a separate "address table" or
"zip code lookup" — not just to save space but to ensure consistency.

---

### 1.5 BCNF, 4NF, 5NF (Advanced)
| Form | What it eliminates |
|---|---|
| BCNF | Every determinant must be a candidate key |
| 4NF | Multi-valued dependencies |
| 5NF | Join dependencies |

In practice: **3NF is the target for most production OLTP systems.**
Going to BCNF/4NF adds complexity without enough benefit in most cases.

---

## Phase 2 — ACID Properties & Transactions
**Goal:** Understand what makes a transactional database reliable

### 2.1 ACID Properties

| Property | What it means | Hospital analogy |
|---|---|---|
| **A**tomicity | All or nothing — transaction either fully completes or fully rolls back | Prescribing a medication + updating inventory: both happen or neither happens |
| **C**onsistency | Data always moves from one valid state to another | A bank account balance can't go negative (constraint enforced) |
| **I**solation | Concurrent transactions don't see each other's intermediate state | Two doctors updating the same patient record don't corrupt each other's changes |
| **D**urability | Committed transactions survive system crashes | Once a prescription is written, a power failure won't lose it |

---

### 2.2 Transaction Isolation Levels
| Level | Dirty Read | Non-repeatable Read | Phantom Read |
|---|---|---|---|
| READ UNCOMMITTED | ✅ possible | ✅ possible | ✅ possible |
| READ COMMITTED | ❌ prevented | ✅ possible | ✅ possible |
| REPEATABLE READ | ❌ prevented | ❌ prevented | ✅ possible |
| SERIALIZABLE | ❌ prevented | ❌ prevented | ❌ prevented |

**SQL Server default:** READ COMMITTED

**Real scenario:** Two nurses read a patient's medication list simultaneously.
Nurse A adds penicillin. Nurse B (at the same moment) reads the list — does she
see penicillin? Depends on isolation level.

---

### 2.3 Locking & Deadlocks
- **Shared lock (S):** Read — multiple readers allowed simultaneously
- **Exclusive lock (X):** Write — no other reads or writes allowed
- **Deadlock:** Thread A holds lock on Table 1, wants Table 2. Thread B holds Table 2, wants Table 1. Neither can proceed → SQL Server kills one.

```sql
-- Detect active locks in SQL Server
SELECT * FROM sys.dm_exec_requests WHERE blocking_session_id <> 0;
```

---

## Phase 3 — Data Synchronisation Between OLTP Systems
**Goal:** Understand how multiple databases stay in sync

### 3.1 Why Sync is Needed

Real hospital scenario:
- **EHR system** (Epic) — patient records
- **Lab system** (Sunquest) — lab results
- **Pharmacy system** (Pyxis) — medication dispensing
- **Billing system** — charges

All four need the same patient data. How do they stay in sync?

### 3.2 Sync Strategies

| Strategy | How it works | When to use |
|---|---|---|
| **Database replication** | SQL Server copies changes to a replica | Read-heavy systems needing a hot standby |
| **CDC (Change Data Capture)** | Capture every INSERT/UPDATE/DELETE in a log | ETL pipelines (what feeds our warehouse) |
| **Message queue (Service Bus)** | Systems publish events, others subscribe | Real-time event-driven architectures |
| **API sync** | Systems call each other's APIs to exchange data | When databases can't talk directly |
| **ETL batch sync** | Nightly job extracts from A, loads into B | Acceptable latency, different schemas |

### 3.3 CDC — Change Data Capture (Most Relevant to ETL)
```sql
-- Enable CDC on a SQL Server database
EXEC sys.sp_cdc_enable_db;

-- Enable on a specific table
EXEC sys.sp_cdc_enable_table
    @source_schema = 'dbo',
    @source_name   = 'patients',
    @role_name     = NULL;

-- Query changes since last sync
SELECT * FROM cdc.dbo_patients_CT
WHERE __$operation IN (1,2,3,4)  -- DELETE, INSERT, UPDATE before, UPDATE after
ORDER BY __$start_lsn;
```

---

## Phase 4 — Database Migration
**Goal:** Understand how to move data from one database to another reliably

### 4.1 Types of Migration

| Type | Description | Example |
|---|---|---|
| **Schema migration** | Changing the structure of an existing DB | Adding columns, renaming tables |
| **Data migration** | Moving data between databases | Legacy system to modern system |
| **Platform migration** | Moving from one DB engine to another | Oracle → SQL Server, SQL Server → PostgreSQL |
| **Version upgrade** | SQL Server 2016 → SQL Server 2022 | Same engine, new version |
| **Cloud migration** | On-premise → Azure SQL / AWS RDS | What Phase 5 of our project does |

### 4.2 Migration Strategies

**Big Bang:** Stop old system, migrate all data, start new system. Simple but risky.

**Phased:** Migrate one module at a time. Less risk, longer timeline.

**Parallel run:** Both systems run simultaneously. Compare outputs. Most expensive but safest.

**Strangler Fig:** Gradually replace old system feature by feature over months/years.

### 4.3 Migration Checklist

1. **Schema analysis** — map source schema to target schema
2. **Data profiling** — understand nulls, formats, ranges, anomalies
3. **Transformation rules** — how does source data map to target?
4. **Validation queries** — row counts, checksums, spot checks
5. **Rollback plan** — what if migration fails at step N?
6. **Cutover plan** — exactly when does the old system go offline?

---

## Phase 5 — Hands-On Project: Hospital Patient Records System

**What we'll build:** A normalised OLTP database for a hospital, demonstrating:
- 3NF schema design
- ACID transactions
- CDC for feeding an ETL pipeline
- Migration from a denormalised "legacy" table to a normalised schema

### Project Schema (3NF)

```sql
-- Core entities (normalised)
CREATE TABLE patients (
    patient_id    INT IDENTITY PRIMARY KEY,
    first_name    VARCHAR(50) NOT NULL,
    last_name     VARCHAR(50) NOT NULL,
    date_of_birth DATE        NOT NULL,
    gender        CHAR(1)     CHECK (gender IN ('M','F','O')),
    zip_code      CHAR(5)     REFERENCES zip_codes(zip_code)
);

CREATE TABLE zip_codes (
    zip_code  CHAR(5)     PRIMARY KEY,
    city      VARCHAR(50) NOT NULL,
    state     CHAR(2)     NOT NULL
);

CREATE TABLE doctors (
    doctor_id   INT IDENTITY PRIMARY KEY,
    first_name  VARCHAR(50) NOT NULL,
    last_name   VARCHAR(50) NOT NULL,
    specialty   VARCHAR(50),
    phone       VARCHAR(15)
);

CREATE TABLE diagnoses (
    icd10_code    CHAR(7)      PRIMARY KEY,
    description   VARCHAR(200) NOT NULL,
    category      VARCHAR(100)
);

CREATE TABLE visits (
    visit_id    INT IDENTITY PRIMARY KEY,
    patient_id  INT  NOT NULL REFERENCES patients(patient_id),
    doctor_id   INT  NOT NULL REFERENCES doctors(doctor_id),
    visit_date  DATE NOT NULL,
    visit_type  VARCHAR(50)  -- Outpatient, Emergency, Inpatient
);

CREATE TABLE visit_diagnoses (
    visit_id      INT    NOT NULL REFERENCES visits(visit_id),
    icd10_code    CHAR(7) NOT NULL REFERENCES diagnoses(icd10_code),
    is_primary    BIT    NOT NULL DEFAULT 1,
    PRIMARY KEY (visit_id, icd10_code)
);

CREATE TABLE medications (
    medication_id   INT IDENTITY PRIMARY KEY,
    name            VARCHAR(100) NOT NULL,
    dosage_form     VARCHAR(50),  -- Tablet, Liquid, Injection
    strength        VARCHAR(20)
);

CREATE TABLE prescriptions (
    prescription_id  INT IDENTITY PRIMARY KEY,
    visit_id         INT  NOT NULL REFERENCES visits(visit_id),
    medication_id    INT  NOT NULL REFERENCES medications(medication_id),
    dosage           VARCHAR(50),
    frequency        VARCHAR(50),
    days_supply      TINYINT,
    prescribed_date  DATE NOT NULL DEFAULT GETDATE()
);
```

### Project Phases

| Phase | Task | Concept Learned |
|---|---|---|
| 1 | Design 3NF schema above | Normalisation in practice |
| 2 | Load "messy" legacy data using ETL | Data migration + transformation |
| 3 | Write ACID transactions for common operations | Transactions + rollback |
| 4 | Enable CDC and query change log | CDC for ETL pipelines |
| 5 | Build a simple star schema from the OLTP (mini-warehouse) | OLTP → OLAP migration |
| 6 | Compare query performance: 3NF vs star schema | Why both exist |

---

## Project Exercises

### Exercise 1 — Normalisation
Given this denormalised legacy table, split it into 3NF:
```sql
CREATE TABLE legacy_visits (
    visit_id        INT,
    patient_name    VARCHAR(100),
    patient_dob     DATE,
    patient_city    VARCHAR(50),
    patient_state   CHAR(2),
    patient_zip     CHAR(5),
    doctor_name     VARCHAR(100),
    doctor_phone    VARCHAR(15),
    doctor_specialty VARCHAR(50),
    visit_date      DATE,
    diagnosis_1     VARCHAR(200),
    diagnosis_2     VARCHAR(200),
    diagnosis_3     VARCHAR(200),
    medication_name VARCHAR(100),
    medication_dose VARCHAR(50)
);
```

### Exercise 2 — ACID Transaction
Write a SQL transaction that:
1. Creates a new visit
2. Records two diagnoses
3. Creates a prescription
4. Rolls back everything if any step fails

### Exercise 3 — Data Migration
Migrate data from `legacy_visits` into the normalised 3NF schema.
Validate: row counts, no orphan FKs, all diagnoses mapped.

### Exercise 4 — CDC
Enable CDC on `patients` table. Insert a new patient, update their
zip code, then query the CDC log to see what was captured.

### Exercise 5 — OLTP to Mini-Warehouse
Build a simple star schema (fact_visits, dim_patient, dim_doctor, dim_date)
from the OLTP tables. Compare: how many joins does a query need in 3NF vs star?

---

## Key Differences Summary: OLTP vs OLAP (Our Warehouse)

| Aspect | OLTP (Hospital System) | OLAP (COVID Warehouse) |
|---|---|---|
| Schema | 3NF — 8+ tables, many joins | Star — 5 tables, simple joins |
| Data volume | Thousands of rows/day | Millions of rows, loaded nightly |
| Transactions | Yes — ACID required | No — bulk load only |
| Indexes | Clustered on PK, many non-clustered | Clustered on partition key |
| History | Current state (SCD Type 2 for history) | Full history always present |
| Sync | Real-time via CDC/replication | Nightly batch ETL |
| Users | 1,000+ concurrent clinical users | 10-20 analysts |

---

## Resources

| Topic | Resource |
|---|---|
| Normalisation | "Database Design for Mere Mortals" — Michael Hernandez |
| ACID + Transactions | Microsoft Docs — Transactions (SQL Server) |
| CDC | Microsoft Docs — About CDC (SQL Server) |
| Migration | Redgate SQL Compare (schema migration tool — free trial) |
| 3NF vs Star Schema | Kimball Group articles |
