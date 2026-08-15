#!/usr/bin/env bash

# error out when undeclared variable is used
set -u 

# must be sourced for exports to continue to the next script
if [ "$0" == "$BASH_SOURCE" ]; then
  echo "Script is being executed directly. Please run as source $0"
  return 1
fi

if [[ "$DML_INTERVAL_SEC" -eq 0 ]] && [[ "${DB_SCHEMA}" != *"_${DML_INTERVAL_SEC}tps"* ]]; then
    DB_SCHEMA="${DB_SCHEMA}_${DML_INTERVAL_SEC}tps"
    echo "Changing schema to $DB_SCHEMA"
fi

if [[ "$INITIAL_SNAPSHOT_ROWS" -eq 0 ]] && [[ "${DB_SCHEMA}" != *"_${INITIAL_SNAPSHOT_ROWS}row"* ]]; then
    DB_SCHEMA="${DB_SCHEMA}_${INITIAL_SNAPSHOT_ROWS}row"
    echo "Changing schema to $DB_SCHEMA"
fi

export DB_SCHEMA
export DB_SCHEMA_SCH="${DB_SCHEMA}_sch"

_POSTGRES_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-.}")" && pwd)"
export _POSTGRES_DIR
_LFC_REPO_ROOT="${_LFC_REPO_ROOT:-$(cd "${_POSTGRES_DIR}/.." && pwd)}"
export _LFC_REPO_ROOT

# #############################################################################
# Per-pipeline slot/publication helpers (always defined; callable from 03/06)
# Names: slot=${WHOAMI}_${NINE_CHAR_ID}  pub=${WHOAMI}_${NINE_CHAR_ID}_pub

db_replication_cleanup() {
    local GATEWAY_PIPELINE_ID=${1:-$GATEWAY_PIPELINE_ID}

    DB_CATALOG="postgres" SQLCLI -c "select slot_name FROM pg_replication_slots where slot_name like 'dbx_%_$GATEWAY_PIPELINE_ID'" </dev/null
    read -rd "\n" -a slot_names <<< "$(cat /tmp/psql_stdout.$$)"
    if [[ -n "${slot_names[*]}" ]]; then
        echo "slot name cleanup"
        for slot_name in "${slot_names[@]}"; do
            DB_CATALOG="postgres" SQLCLI -c "select pg_drop_replication_slot('$slot_name');" 
        done
    fi
}
export -f db_replication_cleanup

db_orphaned_publication_cleanup() {
    echo "cleaning orphaned postgres publications"
    echo "
            DO \$\$
            DECLARE
                pub_record RECORD;
                has_active_slots BOOLEAN;
            BEGIN
                -- Check if there are any active slots at all
                SELECT EXISTS(SELECT 1 FROM pg_replication_slots WHERE active = true) INTO has_active_slots;
                
                -- Only drop publications if no active slots exist
                IF NOT has_active_slots THEN
                    FOR pub_record IN 
                        SELECT pubname
                        FROM pg_publication
                        WHERE pubname LIKE 'dbx_pub_%' OR pubname LIKE '%_pub'
                    LOOP
                        RAISE NOTICE 'Dropping publication: %', pub_record.pubname;
                        EXECUTE format('DROP PUBLICATION IF EXISTS %I', pub_record.pubname);
                    END LOOP;
                END IF;
            END \$\$;
    " | DB_CATALOG="postgres" SQLCLI
}
export -f db_orphaned_publication_cleanup

# Create publication + pgoutput slot for one pipeline run. Tables must already exist.
db_setup_pipeline_slot_pub() {
    local nine_char_id="${1:?NINE_CHAR_ID required}"
    local slot_name="${WHOAMI}_${nine_char_id}"
    local pub_name="${slot_name}_pub"
    local ddl_audit="${DDL_AUDIT_TABLE:-lakeflow_ddl_audit_table_1_0}"

    echo "Creating publication ${pub_name} and slot ${slot_name} (pgoutput)"

    if ! DB_EXIT_ON_ERROR="PRINT_RETURN" DB_CATALOG="${DB_CATALOG}" SQLCLI <<EOF
CREATE PUBLICATION ${pub_name} FOR TABLE
  ${DB_SCHEMA}.intpk, ${DB_SCHEMA}.strpk, ${DB_SCHEMA}.dtix,
  ${DB_SCHEMA_SCH}.intpk_sch, ${DB_SCHEMA_SCH}.strpk_sch, ${DB_SCHEMA_SCH}.dtix_sch;
SELECT 'init' FROM pg_create_logical_replication_slot('${slot_name}', 'pgoutput');
EOF
    then
        echo "ERROR: failed to create publication/slot ${pub_name} / ${slot_name}" >&2
        cat /tmp/psql_stdout.$$ /tmp/psql_stderr.$$
        return 1
    fi

    # Add DDL audit table to this pipeline's publication when present
    DB_EXIT_ON_ERROR="PRINT_RETURN" DB_USERNAME="${DBA_USERNAME}" DB_PASSWORD="${DBA_PASSWORD}" \
      DB_CATALOG="${DB_CATALOG}" SQLCLI <<EOF
DO \$\$
BEGIN
  IF EXISTS (
    SELECT 1 FROM pg_tables
    WHERE schemaname = 'public' AND tablename = '${ddl_audit}'
  ) AND NOT EXISTS (
    SELECT 1 FROM pg_publication_tables
    WHERE pubname = '${pub_name}'
      AND schemaname = 'public'
      AND tablename = '${ddl_audit}'
  ) THEN
    EXECUTE format('ALTER PUBLICATION %I ADD TABLE public.%I', '${pub_name}', '${ddl_audit}');
  END IF;
END \$\$;
EOF

    DB_EXIT_ON_ERROR="PRINT_RETURN" DB_CATALOG="${DB_CATALOG}" SQLCLI -c \
      "SELECT slot_name, plugin FROM pg_replication_slots WHERE slot_name = '${slot_name}' AND plugin = 'pgoutput'" </dev/null
    if ! grep -qE "^${slot_name},pgoutput$" /tmp/psql_stdout.$$; then
        echo "ERROR: logical replication slot ${slot_name} with pgoutput does not exist" >&2
        cat /tmp/psql_stdout.$$ /tmp/psql_stderr.$$
        return 1
    fi

    DB_EXIT_ON_ERROR="PRINT_RETURN" DB_CATALOG="${DB_CATALOG}" SQLCLI -c \
      "SELECT pubname FROM pg_publication WHERE pubname = '${pub_name}'" </dev/null
    if ! grep -qE "^${pub_name}$" /tmp/psql_stdout.$$; then
        echo "ERROR: publication ${pub_name} does not exist" >&2
        cat /tmp/psql_stdout.$$ /tmp/psql_stderr.$$
        return 1
    fi

    echo "replication ok slot=${slot_name} pub=${pub_name} ${DB_HOST_FQDN},${DB_PORT}"
    export PG_SLOT_NAME="${slot_name}"
    export PG_PUBLICATION_NAME="${pub_name}"
}
export -f db_setup_pipeline_slot_pub

# Drop per-pipeline slot then publication (used by 06_manual_delete).
db_drop_pipeline_slot_pub() {
    local nine_char_id="${1:?NINE_CHAR_ID required}"
    local slot_name="${WHOAMI}_${nine_char_id}"
    local pub_name="${slot_name}_pub"

    echo "Dropping slot ${slot_name} and publication ${pub_name}"

    DB_EXIT_ON_ERROR="PRINT_RETURN" DB_CATALOG="${DB_CATALOG:-postgres}" SQLCLI <<EOF
DO \$\$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_replication_slots WHERE slot_name = '${slot_name}') THEN
    PERFORM pg_drop_replication_slot('${slot_name}');
  END IF;
END \$\$;
DROP PUBLICATION IF EXISTS ${pub_name};
EOF
}
export -f db_drop_pipeline_slot_pub

# Load helpers only (03/06): skip schema/table/replica main configure.
if [[ "${PG_CONFIGURE_MAIN:-1}" != "1" ]]; then
    return 0
fi

echo "Demo schemas: DB_SCHEMA=${DB_SCHEMA} (per-table) DB_SCHEMA_SCH=${DB_SCHEMA_SCH} (*_sch tables)"

# #############################################################################
# dml generator for postgres

# make sure to quote echo "$sql_dml_generator" otherwise the newline will be removed 
if ! declare -p sql_dml_generator &> /dev/null; then
echo "using default sql_dml_generator.  echo \"\$sql_dml_generator\" to view"
_sql_dml_body=""
for _sfx in "" "_sch"; do
  if [[ -z "${_sfx}" ]]; then
    _schema="${DB_SCHEMA}"
  else
    _schema="${DB_SCHEMA_SCH}"
  fi
  _sql_dml_body+="
        insert into ${_schema}.intpk${_sfx} (dt) values (CURRENT_TIMESTAMP),(CURRENT_TIMESTAMP), (CURRENT_TIMESTAMP);
        delete from ${_schema}.intpk${_sfx} where pk=(select min(pk) from ${_schema}.intpk${_sfx});
        update ${_schema}.intpk${_sfx} set dt=CURRENT_TIMESTAMP where pk=(select min(pk) from ${_schema}.intpk${_sfx});
        insert into ${_schema}.strpk${_sfx} (dt) values (CURRENT_TIMESTAMP),(CURRENT_TIMESTAMP),(CURRENT_TIMESTAMP);
        delete from ${_schema}.strpk${_sfx} where pk=(select min(pk) from ${_schema}.strpk${_sfx});
        update ${_schema}.strpk${_sfx} set dt=CURRENT_TIMESTAMP where pk=(select min(pk) from ${_schema}.strpk${_sfx});
        insert into ${_schema}.dtix${_sfx} (dt) values (CURRENT_TIMESTAMP),(CURRENT_TIMESTAMP),(CURRENT_TIMESTAMP);"
done
sql_dml_generator="
do \$\$
declare
    counter integer := 0;
begin
    while counter >= 0 loop
${_sql_dml_body}
        commit;
        raise notice 'Counter %', counter;
        counter := counter + 1;
        perform pg_sleep('${DML_INTERVAL_SEC}');
    end loop;
end;
\$\$;
"
fi

# #############################################################################

# connect to postgres catalog as DBA
DB_EXIT_ON_ERROR="PRINT_EXIT" DB_USERNAME="$DBA_USERNAME" DB_PASSWORD="$DBA_PASSWORD" DB_CATALOG="postgres" TEST_DB_CONNECT

# #############################################################################
# create user login.  user by default = role + login

# Drop stale auto-picks of Lakeflow/system roles (e.g. from DDL audit objects).
if [[ -n "${USER_USERNAME:-}" ]] && [[ "${USER_USERNAME}" == lakeflow_* || "${USER_USERNAME}" == azure* || "${USER_USERNAME}" == pg_* ]]; then
    echo "USER_USERNAME=${USER_USERNAME} looks like a system/Lakeflow role; resetting to USER_BASENAME=${USER_BASENAME}"
    USER_USERNAME="${USER_BASENAME}"
fi

if [[ -z "$USER_USERNAME" || "$USER_USERNAME" == "$USER_BASENAME" ]]; then
    DB_CATALOG="postgres" SQLCLI_DBA -c "
        select usename from pg_user
        where usename not in ('azuresu', 'rdsadmin', 'replication', 'azure_pg_admin', 'azure_superuser')
          and usename not like 'pg\\_%'
          and usename not like 'azure%'
          and usename not like 'lakeflow\\_%'
          and usename <> '${DBA_USERNAME}'
        order by usename
    " </dev/null
    if [[ -s /tmp/psql_stdout.$$ ]] && grep -q -m 1 '.' /tmp/psql_stdout.$$; then
        USER_USERNAME=$(head -n 1 /tmp/psql_stdout.$$)
        echo "Retrieving USER_USERNAME=$USER_USERNAME"
    else
        USER_USERNAME="$USER_BASENAME"
        echo "Setting USER_USERNAME=$USER_BASENAME"
    fi
fi

DB_CATALOG="postgres" SQLCLI_DBA <<EOF
do \$\$ begin
if not exists (select * from pg_user where usename = '${USER_USERNAME}') THEN
    create user ${USER_USERNAME} password '${USER_PASSWORD}';
end if;
end \$\$;
alter user ${USER_USERNAME} with password '${USER_PASSWORD}';
grant connect on database ${DB_CATALOG} to ${USER_USERNAME};
grant all privileges on database ${DB_CATALOG} to ${USER_USERNAME};
-- works on azure postgres flexible server
alter role $USER_USERNAME with replication;
-- works on aws rds postgres
grant rds_replication to $USER_USERNAME;
select 1;
EOF

# connect to postgres as a user
DB_EXIT_ON_ERROR="PRINT_EXIT" DB_USERNAME="$USER_USERNAME" DB_PASSWORD="$USER_PASSWORD" DB_CATALOG="postgres" TEST_DB_CONNECT

# #############################################################################
# create user in the catalog

# connect to $DB_CATALOG as a user
DB_EXIT_ON_ERROR="PRINT_EXIT" DB_USERNAME="$USER_USERNAME" DB_PASSWORD="$USER_PASSWORD" DB_CATALOG="$DB_CATALOG" TEST_DB_CONNECT

# #############################################################################

# database enable / disable logical replica

DB_CATALOG="postgres" SQLCLI_DBA -c "SHOW wal_level" </dev/null

if [[ "logical" == $(cat /tmp/psql_stdout.$$) ]]; then echo "logical replica enable ok $DB_CATALOG catalog $DB_HOST_FQDN,${DB_PORT} $DBA_USERNAME"; 
else cat /tmp/psql_stdout.$$ /tmp/psql_stderr.$$
    return 1
fi

# #############################################################################

# create schemas: DB_SCHEMA (per-table) + DB_SCHEMA_SCH (*_sch tables)

echo -e "Creating schemas ${DB_SCHEMA} and ${DB_SCHEMA_SCH} owned by ${USER_USERNAME}\n"

for _demo_schema in "${DB_SCHEMA}" "${DB_SCHEMA_SCH}"; do
DB_EXIT_ON_ERROR="PRINT_EXIT" DB_CATALOG="$DB_CATALOG" SQLCLI_DBA <<EOF
CREATE SCHEMA IF NOT EXISTS ${_demo_schema} AUTHORIZATION ${USER_USERNAME};
ALTER SCHEMA ${_demo_schema} OWNER TO ${USER_USERNAME};
GRANT ALL ON SCHEMA ${_demo_schema} TO ${USER_USERNAME};
GRANT ALL ON ALL TABLES IN SCHEMA ${_demo_schema} TO ${USER_USERNAME};
GRANT ALL ON ALL SEQUENCES IN SCHEMA ${_demo_schema} TO ${USER_USERNAME};
ALTER DEFAULT PRIVILEGES IN SCHEMA ${_demo_schema} GRANT ALL ON TABLES TO ${USER_USERNAME};
ALTER DEFAULT PRIVILEGES IN SCHEMA ${_demo_schema} GRANT ALL ON SEQUENCES TO ${USER_USERNAME};
SELECT 1;
EOF
if [[ ! -s /tmp/psql_stderr.$$ ]] && [[ -n "${DELETE_DB_AFTER_SLEEP}" ]]; then
    if [[ "${_demo_schema}" == "${DB_SCHEMA_SCH}" ]]; then
      _sfx="_sch"
    else
      _sfx=""
    fi
    _drops="drop table if exists ${_demo_schema}.intpk${_sfx};
    drop table if exists ${_demo_schema}.strpk${_sfx};
    drop table if exists ${_demo_schema}.dtix${_sfx};"
    nohup sleep "${DELETE_DB_AFTER_SLEEP}" && DB_STDOUT=~/nohup.out DB_STDERR=~/nohup.out DB_CATALOG="$DB_CATALOG" SQLCLI >>~/nohup.out 2>&1 << EOF &
    ${_drops}
    drop schema if exists ${_demo_schema};
EOF
    echo -e "\nDeleting ${_demo_schema} schema after ${DELETE_DB_AFTER_SLEEP}.  To cancel kill -9 $!\n"
fi
done

# #############################################################################

# create tables

echo -e "Creating tables in ${DB_SCHEMA} and ${DB_SCHEMA_SCH}\n"

# Recreate strpk* so UUID default applies (IF NOT EXISTS would keep old DDL)
for _sfx in "" "_sch"; do
  if [[ -z "${_sfx}" ]]; then
    _schema="${DB_SCHEMA}"
  else
    _schema="${DB_SCHEMA_SCH}"
  fi

  DB_EXIT_ON_ERROR="PRINT_EXIT" DB_CATALOG="$DB_CATALOG" SQLCLI <<EOF
    drop table if exists ${_schema}.strpk${_sfx};
    create table if not exists ${_schema}.intpk${_sfx} (pk serial primary key, dt timestamp);
    create table ${_schema}.strpk${_sfx} (pk text primary key default gen_random_uuid()::text, dt timestamp);
    create table if not exists ${_schema}.dtix${_sfx} (dt timestamp);
EOF

  DB_EXIT_ON_ERROR="PRINT_EXIT" DB_CATALOG="$DB_CATALOG" SQLCLI_DBA <<EOF
ALTER TABLE IF EXISTS ${_schema}.intpk${_sfx} OWNER TO ${USER_USERNAME};
ALTER TABLE IF EXISTS ${_schema}.strpk${_sfx} OWNER TO ${USER_USERNAME};
ALTER TABLE IF EXISTS ${_schema}.dtix${_sfx} OWNER TO ${USER_USERNAME};
GRANT ALL ON ALL TABLES IN SCHEMA ${_schema} TO ${USER_USERNAME};
GRANT ALL ON ALL SEQUENCES IN SCHEMA ${_schema} TO ${USER_USERNAME};
SELECT 1;
EOF

  if [[ "$INITIAL_SNAPSHOT_ROWS" -gt 0 ]]; then
    DB_EXIT_ON_ERROR="PRINT_EXIT" DB_CATALOG="$DB_CATALOG" SQLCLI <<EOF
    insert into ${_schema}.intpk${_sfx} (dt) values (CURRENT_TIMESTAMP),(CURRENT_TIMESTAMP), (CURRENT_TIMESTAMP);
    insert into ${_schema}.strpk${_sfx} (dt) values (CURRENT_TIMESTAMP),(CURRENT_TIMESTAMP), (CURRENT_TIMESTAMP);
    insert into ${_schema}.dtix${_sfx} (dt) values (CURRENT_TIMESTAMP),(CURRENT_TIMESTAMP),(CURRENT_TIMESTAMP);
    select '${_schema}.intpk${_sfx}',max(pk) from ${_schema}.intpk${_sfx};
    select '${_schema}.strpk${_sfx}',max(pk) from ${_schema}.strpk${_sfx};
    select '${_schema}.dtix${_sfx}',dt from ${_schema}.dtix${_sfx} limit 1;
EOF
    for _t in "${_schema}.intpk${_sfx}" "${_schema}.strpk${_sfx}" "${_schema}.dtix${_sfx}"; do
      if grep "^${_t},.\+$" /tmp/psql_stdout.$$; then echo "table ok ${_t}"; else cat /tmp/psql_stdout.$$ /tmp/psql_stderr.$$; return 1; fi
    done
  fi
done

# #############################################################################
# No default slot/publication here — 03 calls db_setup_pipeline_slot_pub per pipeline.

echo "Skipping default slot/publication create (per-pipeline via db_setup_pipeline_slot_pub from 03)"

# #############################################################################
# Optional: inline DDL change tracking (Lakeflow PG DDL audit objects)

echo -e "\nInstalling Lakeflow PG DDL change-tracking (latest registered)"
echo -e   "-------------------------------------------------------------\n"

DB_USERNAME="${DBA_USERNAME}" DB_PASSWORD="${DBA_PASSWORD}" DB_CATALOG="${DB_CATALOG}" \
  python3 "${_LFC_REPO_ROOT}/utils/postgres-ddl-change-tracking.py" \
    --apply || return 1

DDL_AUDIT_TABLE="lakeflow_ddl_audit_table_1_0"
export DDL_AUDIT_TABLE

# Verify audit objects (ALTER PUBLICATION for audit table is done in db_setup_pipeline_slot_pub)
DB_EXIT_ON_ERROR="PRINT_EXIT" DB_USERNAME="${DBA_USERNAME}" DB_PASSWORD="${DBA_PASSWORD}" \
  DB_CATALOG="${DB_CATALOG}" SQLCLI -c "SELECT tablename FROM pg_tables WHERE schemaname='public' AND tablename LIKE 'lakeflow_ddl_audit_table%';" </dev/null
if ! grep -q "${DDL_AUDIT_TABLE}" /tmp/psql_stdout.$$; then
    echo "ERROR: DDL audit table ${DDL_AUDIT_TABLE} not found after install" >&2
    cat /tmp/psql_stdout.$$ /tmp/psql_stderr.$$
    return 1
fi
echo "DDL audit table ok: ${DDL_AUDIT_TABLE}"

DB_EXIT_ON_ERROR="PRINT_EXIT" DB_USERNAME="${DBA_USERNAME}" DB_PASSWORD="${DBA_PASSWORD}" \
  DB_CATALOG="${DB_CATALOG}" SQLCLI -c "SELECT evtname FROM pg_event_trigger WHERE evtname LIKE 'lakeflow%';" </dev/null
if ! grep -q "lakeflow_ddl_audit_trigger" /tmp/psql_stdout.$$; then
    echo "ERROR: lakeflow DDL event triggers not found after install" >&2
    cat /tmp/psql_stdout.$$ /tmp/psql_stderr.$$
    return 1
fi
echo "DDL event triggers ok"

# #############################################################################

# enable replication tables

DB_OUT_SUFFIX="replication_table" DB_EXIT_ON_ERROR="PRINT_EXIT" SQLCLI </dev/null -c "
    SELECT nspname, relname, relreplident
    FROM pg_class as c JOIN pg_namespace AS ns ON c.relnamespace = ns.oid
    WHERE (nspname = '${DB_SCHEMA}' AND relname in ('dtix','intpk','strpk'))
       OR (nspname = '${DB_SCHEMA_SCH}' AND relname in ('dtix_sch','intpk_sch','strpk_sch'))
"

# Helper: set replica identity for one table
_pg_set_replica() {
    local sch="$1" tbl="$2" want="$3"  # want: f|d|n
    local label="$4"
    if [[ -n $(grep "${sch},${tbl},${want}" /tmp/psql_stdout_replication_table.$$) ]]; then
        echo "table ${tbl} replica ${label} ok ${sch}"
    else
        case "$want" in
          f) SQLCLI </dev/null -c "alter table ${sch}.${tbl} replica identity full;" ;;
          d) SQLCLI </dev/null -c "alter table ${sch}.${tbl} replica identity default;" ;;
          n) SQLCLI </dev/null -c "alter table ${sch}.${tbl} replica identity nothing;" ;;
        esac
    fi
}

# CDC path: dtix+strpk → full; CT path: intpk → default; else nothing
_cdc_on=0
_ct_on=0
case "${CDC_CT_MODE}" in
  BOTH|CDC|NONE) _cdc_on=1 ;;
esac
case "${CDC_CT_MODE}" in
  BOTH|CT|NONE) _ct_on=1 ;;
esac

for _pair in "${DB_SCHEMA}:" "${DB_SCHEMA_SCH}:_sch"; do
  _sch="${_pair%%:*}"
  _sfx="${_pair#*:}"
  if [[ "${_cdc_on}" -eq 1 ]]; then
    _pg_set_replica "${_sch}" "dtix${_sfx}" f full
    _pg_set_replica "${_sch}" "strpk${_sfx}" f full
  else
    _pg_set_replica "${_sch}" "dtix${_sfx}" n nothing
    _pg_set_replica "${_sch}" "strpk${_sfx}" n nothing
  fi
  if [[ "${_ct_on}" -eq 1 ]]; then
    _pg_set_replica "${_sch}" "intpk${_sfx}" d default
  else
    _pg_set_replica "${_sch}" "intpk${_sfx}" n nothing
  fi
done

# #############################################################################

echo -e "\n
Run the following steps:
------------------------

source  <(curl -s -L https://raw.githubusercontent.com/rsleedbx/lakeflow_connect/refs/heads/main/03_lakeflow_connect_demo.sh)
"
