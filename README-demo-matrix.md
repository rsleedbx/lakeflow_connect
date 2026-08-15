# Demo coverage matrix

- **Source database:** MySQL, PostgreSQL (PG), SQL Server
- **CDC Method**: cdc, ct
- **Hosting:** AWS, Azure, GCP, on-premises (on-prem)
- **Primary key:** with PK, no PK
- **Cursor column:** with cursor, no cursor
- **Ingestion scope:** schema, per table
- **Replication mode:** SCD Type 1 (SCD1), SCD Type 2 (SCD2), append-only
- **Ingestion method:** Query-Based Connector foreign catalog (`qbc_fc` = UC `FOREIGN_CATALOG` / `IngestFromUcForeignCatalog`), Query-Based Connector foreign connection (`qbc_fcon`), Change Data Capture (CDC), Integrated CDC (ICDC)

Constraints (product-supported surface; see universe-notes `lakeflow-connect-sources.md` and `lakeflow-connect-foreign-catalog-connection.md`):

- SQL Server is the only source with CT; MySQL/PG are CDC-only. Capture (`cdc`/`ct`) applies only to CDC/ICDC ingest.
- Cursor: `qbc_fc` / `qbc_fcon` always set `query_based_connector_config.cursor_columns=["dt"]` for every SCD type. CDC/ICDC do not set cursor config (gateway rejects QBC config).
- Append-only: **`qbc_fc` / `qbc_fcon` only** (all sources). CDC/ICDC do not use `APPEND_ONLY` (API requires QBC + cursor; demo uses SCD2 for `dtix`).
- `qbc_fc` is the foreign-catalog QBC path (not a separate third stack beside FC).
- `qbc_fcon` supports per-table scope only (no schema/`DATABASE` selection in QUERY UI).
- SQL Server CT: SCD1 only (no SCD2 / append).

## Per-table SCD (hardcoded)

| SOURCE_TYPE | CDC_QBC | CDC_CT_MODE | intpk | strpk | dtix |
|---|---|---|---|---|---|
| any | `qbc_fc` / `qbc_fcon` | n/a | SCD1 | SCD2 | append-only (+ cursor `dt`) |
| MYSQL | `cdc` / `icdc` | n/a | SCD1 | SCD2 | SCD2 |
| POSTGRESQL | `cdc` / `icdc` | n/a | SCD1 | SCD2 | SCD2 |
| SQLSERVER | `cdc` / `icdc` | `BOTH` or `CDC` | SCD1 | SCD2 | SCD2 |
| SQLSERVER | `cdc` / `icdc` | `CT` | SCD1 | SCD1 | SCD1 |

## Abbreviations

| Abbreviation | Term |
|---|---|
| PG | PostgreSQL |
| on-prem | on-premises |
| PK | primary key |
| SCD1 | Slowly Changing Dimension Type 1 |
| SCD2 | Slowly Changing Dimension Type 2 |
| QBC | Query-Based Connector |
| qbc_fc | Query-Based Connector foreign catalog ingestion (`FOREIGN_CATALOG`) |
| qbc_fcon | Query-Based Connector foreign connection ingestion |
| CDC | Change Data Capture |
| ICDC | Integrated CDC |
| `_sch` | schema-level source schema / table-name suffix (`lfcddemo_sch`, `intpk_sch`, …) |
