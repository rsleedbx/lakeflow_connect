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

_POSTGRES_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-.}")" && pwd)"
export _POSTGRES_DIR
_LFC_REPO_ROOT="${_LFC_REPO_ROOT:-$(cd "${_POSTGRES_DIR}/.." && pwd)}"
export _LFC_REPO_ROOT

# #############################################################################
# dml generator for postgres

# make sure to quote echo "$sql_dml_generator" otherwise the newline will be removed 
if ! declare -p sql_dml_generator &> /dev/null; then
echo "using default sql_dml_generator.  echo \"\$sql_dml_generator\" to view" 
sql_dml_generator='
set search_path='${DB_SCHEMA}';
do $$
declare 
    counter integer := 0;
begin
    while counter >= 0 loop
        -- intpk
        insert into intpk (dt) values (CURRENT_TIMESTAMP),(CURRENT_TIMESTAMP), (CURRENT_TIMESTAMP);
        commit;
        delete from intpk where pk=(select min(pk) from intpk);
        commit;
        update intpk set dt=CURRENT_TIMESTAMP where pk=(select min(pk) from intpk);
        commit;
        -- dtix
        insert into dtix (dt) values (CURRENT_TIMESTAMP),(CURRENT_TIMESTAMP),(CURRENT_TIMESTAMP);
        commit;
        -- wait
		raise notice '"'Counter %'"', counter;
	    counter := counter + 1;
        perform pg_sleep('${DML_INTERVAL_SEC}');
    end loop;
end;
$$;
'
fi

# #############################################################################

# connect to postgres catalog as DBA
DB_EXIT_ON_ERROR="PRINT_EXIT" DB_USERNAME="$DBA_USERNAME" DB_PASSWORD="$DBA_PASSWORD" DB_CATALOG="postgres" TEST_DB_CONNECT

# #############################################################################
# create user login.  user by default = role + login

if [[ -z "$USER_USERNAME" || "$USER_USERNAME" == "$USER_BASENAME" ]]; then
    DB_CATALOG="postgres" SQLCLI_DBA -c "select usename from pg_user where usename not in ('azuresu', 'rdsadmin', 'replication')" </dev/null
    if grep -q -v -m 1 "^${DBA_USERNAME}$" /tmp/psql_stdout.$$; then 
        USER_USERNAME=$(grep -v -m 1 "^${DBA_USERNAME}$" /tmp/psql_stdout.$$)
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

# remove left over slot names
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

db_enable_replication_slot() {
    # Tables must already exist (CREATE PUBLICATION FOR TABLE requires them).
    echo "CREATE PUBLICATION ${DB_SCHEMA}_pub FOR table ${DB_SCHEMA}.intpk, ${DB_SCHEMA}.dtix" | SQLCLI
    echo "SELECT 'init' FROM pg_create_logical_replication_slot('${DB_SCHEMA}', 'pgoutput')" | SQLCLI
    echo "SELECT * FROM pg_replication_slots WHERE slot_name = '${DB_SCHEMA}'" | SQLCLI
}
export -f db_enable_replication_slot

# #############################################################################

# create schema

DB_CATALOG="$DB_CATALOG" SQLCLI -c "create schema if not exists ${DB_SCHEMA}" </dev/null
# /tmp/psql_stdout.$$ will be 0 if schema was created.  drop the schema when done
if [[ ! -s /tmp/psql_stderr.$$ ]] && [[ -n "${DELETE_DB_AFTER_SLEEP}" ]]; then
    nohup sleep "${DELETE_DB_AFTER_SLEEP}" && DB_STDOUT=~/nohup.out DB_STDERR=~/nohup.out DB_CATALOG="$DB_CATALOG" SQLCLI >>~/nohup.out 2>&1 << EOF &
    drop table if exists ${DB_SCHEMA}.intpk; 
    drop table if exists ${DB_SCHEMA}.dtix; 
    drop schema if exists ${DB_SCHEMA};
EOF
    echo -e "\nDeleting ${DB_SCHEMA} schema after ${DELETE_DB_AFTER_SLEEP}.  To cancel kill -9 $!\n" 
fi

# #############################################################################

# create tables

DB_CATALOG="$DB_CATALOG" SQLCLI <<EOF
    create table if not exists ${DB_SCHEMA}.intpk (pk serial primary key, dt timestamp);
    create table if not exists ${DB_SCHEMA}.dtix (dt timestamp);
EOF

if [[ "$INITIAL_SNAPSHOT_ROWS" -gt 0 ]]; then
DB_CATALOG="$DB_CATALOG" SQLCLI <<EOF
    insert into ${DB_SCHEMA}.intpk (dt) values (CURRENT_TIMESTAMP),(CURRENT_TIMESTAMP), (CURRENT_TIMESTAMP);
    insert into ${DB_SCHEMA}.dtix (dt) values (CURRENT_TIMESTAMP),(CURRENT_TIMESTAMP),(CURRENT_TIMESTAMP);
    select '${DB_SCHEMA}.intpk',max(pk) from ${DB_SCHEMA}.intpk;
    select '${DB_SCHEMA}.dtix',dt from ${DB_SCHEMA}.dtix limit 1;    
EOF

# .\+ = one or more so that nulls are not accepted
if grep "^${DB_SCHEMA}.intpk,.\+$" /tmp/psql_stdout.$$; then echo "table intpk ok $DB_SCHEMA schema $DB_HOST_FQDN,${DB_PORT} $DBA_USERNAME"; 
else cat /tmp/psql_stdout.$$ /tmp/psql_stderr.$$
    return 1
fi

# .\+ = one or more so that nulls are not accepted
if grep "^${DB_SCHEMA}.dtix,.\+$" /tmp/psql_stdout.$$ ; then echo "table dtix ok $DB_SCHEMA schema $DB_HOST_FQDN,${DB_PORT} $DBA_USERNAME"; 
else cat /tmp/psql_stdout.$$ /tmp/psql_stderr.$$
    return 1
fi
fi

# #############################################################################
# publication + slot (after tables exist)

db_replication_cleanup
db_orphaned_publication_cleanup
db_enable_replication_slot
# [0-9]+ = datoid; ,${DB_CATALOG}, = database column (non-empty)
if grep -qE "^${DB_SCHEMA},pgoutput,logical,[0-9]+,${DB_CATALOG}," /tmp/psql_stdout.$$; then
    echo "replication ok $DB_SCHEMA schema $DB_HOST_FQDN,${DB_PORT} $DBA_USERNAME"
else
    cat /tmp/psql_stdout.$$ /tmp/psql_stderr.$$
    return 1
fi

# #############################################################################
# Optional: inline DDL change tracking (Lakeflow PG DDL audit objects)

echo -e "\nInstalling Lakeflow PG DDL change-tracking (latest registered)"
echo -e   "-------------------------------------------------------------\n"

DB_USERNAME="${DBA_USERNAME}" DB_PASSWORD="${DBA_PASSWORD}" DB_CATALOG="${DB_CATALOG}" \
  python3 "${_LFC_REPO_ROOT}/utils/postgres-ddl-change-tracking.py" \
    --apply || return 1

# Add audit table to the demo publication (must run as publication owner / DBA)
DDL_AUDIT_TABLE="lakeflow_ddl_audit_table_1_0"
DB_EXIT_ON_ERROR="PRINT_EXIT" DB_USERNAME="${DBA_USERNAME}" DB_PASSWORD="${DBA_PASSWORD}" \
  DB_CATALOG="${DB_CATALOG}" SQLCLI <<EOF
DO \$\$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_publication_tables
    WHERE pubname = '${DB_SCHEMA}_pub'
      AND schemaname = 'public'
      AND tablename = '${DDL_AUDIT_TABLE}'
  ) THEN
    EXECUTE format('ALTER PUBLICATION %I ADD TABLE public.%I', '${DB_SCHEMA}_pub', '${DDL_AUDIT_TABLE}');
  END IF;
END \$\$;
EOF

# Verify audit objects
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

# get the table replication status
DB_OUT_SUFFIX="replication_table" DB_EXIT_ON_ERROR="PRINT_EXIT" SQLCLI </dev/null -c "
    SELECT nspname, relname, relreplident
    FROM pg_class as c JOIN pg_namespace AS ns ON c.relnamespace = ns.oid 
    WHERE nspname in ('$DB_SCHEMA') AND relname in ('dtix','intpk')
" 

# dtix does not have primary key
if [[ "$CDC_CT_MODE" == "BOTH" || "$CDC_CT_MODE" == "CDC" ]]; then
    if [[ -n $(cat /tmp/psql_stdout_replication_table.$$ | grep "${DB_SCHEMA},dtix,f") ]]; 
        then echo "table full replica enabled ok $DB_SCHEMA schema $DB_HOST_FQDN,${DB_PORT} $DBA_USERNAME"; 
    else 
        SQLCLI </dev/null -c "alter table ${DB_SCHEMA}.dtix replica identity full;"
    fi
else
    if [[ -n $(cat /tmp/psql_stdout_replication_table.$$ | grep "${DB_SCHEMA},dtix,n") ]]; 
        then echo "table full replica disabled ok $DB_SCHEMA schema $DB_HOST_FQDN,${DB_PORT} $DBA_USERNAME"; 
    else 
        SQLCLI </dev/null -c "alter table ${DB_SCHEMA}.dtix replica identity nothing;"
    fi
fi

# intpk has primary key
if [[ "$CDC_CT_MODE" == "BOTH" || "$CDC_CT_MODE" == "CT" ]]; then
    if [[ -n $(cat /tmp/psql_stdout_replication_table.$$ | grep "${DB_SCHEMA},intpk,d" ) ]]; then 
        echo "table default replica enabled ok $DB_SCHEMA schema $DB_HOST_FQDN,${DB_PORT} $DBA_USERNAME"; 
    else 
        SQLCLI </dev/null -c "alter table ${DB_SCHEMA}.intpk replica identity default;"
    fi
else
    if [[ -n $(cat /tmp/psql_stdout_replication_table.$$ | grep "${DB_SCHEMA},intpk,n") ]]; 
        then echo "table full replica disabled ok $DB_SCHEMA schema $DB_HOST_FQDN,${DB_PORT} $DBA_USERNAME"; 
    else 
        SQLCLI </dev/null -c "alter table ${DB_SCHEMA}.intpk replica identity nothing;"
    fi
fi

# #############################################################################

echo -e "\n
Run the following steps:
------------------------

source  <(curl -s -L https://raw.githubusercontent.com/rsleedbx/lakeflow_connect/refs/heads/main/03_lakeflow_connect_demo.sh)
"
