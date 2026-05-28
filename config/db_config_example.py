# config/db_config_example.py
#
# INSTRUCTIONS:
# 1. Copy this file to db_config.py
#    cp config/db_config_example.py config/db_config.py
# 2. Fill in your actual credentials in db_config.py
# 3. db_config.py is in .gitignore — it will NEVER be committed
#
# Never put real passwords in this example file.

# ── PostgreSQL (local) ──────────────────────────────────────────
PG_CONFIG = {
    "host":     "localhost",
    "port":     5432,
    "database": "covid_dw",
    "user":     "YOUR_POSTGRES_USER",
    "password": "YOUR_POSTGRES_PASSWORD",
}

# Connection string for SQLAlchemy
PG_CONNECTION_STRING = (
    f"postgresql://{PG_CONFIG['user']}:{PG_CONFIG['password']}"
    f"@{PG_CONFIG['host']}:{PG_CONFIG['port']}/{PG_CONFIG['database']}"
)

# ── Snowflake (Phase 5) ─────────────────────────────────────────
SNOWFLAKE_CONFIG = {
    "account":   "YOUR_SNOWFLAKE_ACCOUNT",   # e.g. abc12345.us-east-1
    "user":      "YOUR_SNOWFLAKE_USER",
    "password":  "YOUR_SNOWFLAKE_PASSWORD",
    "warehouse": "COMPUTE_WH",
    "database":  "COVID_DW",
    "schema":    "PUBLIC",
}
