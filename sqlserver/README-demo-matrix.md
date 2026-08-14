# Demo coverage matrix

- **Source database:** MySQL, PostgreSQL (PG), SQL Server
- **Hosting:** AWS, Azure, GCP, on-premises (on-prem)
- **Primary key:** with PK, with synthetic hash PK, no PK
- **Cursor column:** with cursor, no cursor
- **Ingestion scope:** one destination (`TARGET_SCHEMA`); two source schemas in one demo run — no env toggle
  - **Per-table:** `DB_SCHEMA` (e.g. `${WHOAMI}_lfcddemo`) with tables `intpk`, `strpk`, `dtix`
  - **Schema-level:** `DB_SCHEMA_SCH` (`${DB_SCHEMA}_sch`, e.g. `…_lfcddemo_sch`) with tables `intpk_sch`, `strpk_sch`, `dtix_sch`
- **Replication mode:** SCD Type 1 (SCD1), SCD Type 2 (SCD2), append-only
- **Ingestion method:** foreign catalog, Query-Based Connector foreign catalog (`qbc_fc`), Query-Based Connector foreign connection (`qbc_fcon`), Change Data Capture (CDC), Integrated CDC (ICDC)

`qbc_fc` ingests both scopes in one pipeline into `TARGET_SCHEMA`: schema object from `DB_SCHEMA_SCH` (`*_sch` tables), plus per-table SCD objects from `DB_SCHEMA`. Distinct source table names avoid LFC collisions when landing into a single target.

## Abbreviations

| Abbreviation | Term |
|---|---|
| PG | PostgreSQL |
| on-prem | on-premises |
| PK | primary key |
| SCD1 | Slowly Changing Dimension Type 1 |
| SCD2 | Slowly Changing Dimension Type 2 |
| QBC | Query-Based Connector |
| qbc_fc | Query-Based Connector foreign catalog ingestion |
| qbc_fcon | Query-Based Connector foreign connection ingestion |
| CDC | Change Data Capture |
| ICDC | Integrated CDC |
| `_sch` | schema-level source schema / table-name suffix (`lfcddemo_sch`, `intpk_sch`, …) |
