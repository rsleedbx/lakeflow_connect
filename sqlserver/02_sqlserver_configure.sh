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
echo "Demo schemas: DB_SCHEMA=${DB_SCHEMA} (per-table) DB_SCHEMA_SCH=${DB_SCHEMA_SCH} (*_sch tables)"

# #############################################################################
# dml generator

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
IF OBJECT_ID(N'${_schema}.intpk${_sfx}', N'U') IS NOT NULL
    begin
    insert into [${_schema}].[intpk${_sfx}] (dt) values (CURRENT_TIMESTAMP),(CURRENT_TIMESTAMP), (CURRENT_TIMESTAMP)
    delete from [${_schema}].[intpk${_sfx}] where pk=(select min(pk) from [${_schema}].[intpk${_sfx}])
    update [${_schema}].[intpk${_sfx}] set dt=CURRENT_TIMESTAMP where pk=(select min(pk) from [${_schema}].[intpk${_sfx}])
    end
IF OBJECT_ID(N'${_schema}.strpk${_sfx}', N'U') IS NOT NULL
    begin
    insert into [${_schema}].[strpk${_sfx}] (dt) values (CURRENT_TIMESTAMP),(CURRENT_TIMESTAMP),(CURRENT_TIMESTAMP)
    delete from [${_schema}].[strpk${_sfx}] where pk=(select min(pk) from [${_schema}].[strpk${_sfx}])
    update [${_schema}].[strpk${_sfx}] set dt=CURRENT_TIMESTAMP where pk=(select min(pk) from [${_schema}].[strpk${_sfx}])
    end
IF OBJECT_ID(N'${_schema}.dtix${_sfx}', N'U') IS NOT NULL
    insert into [${_schema}].[dtix${_sfx}] (dt) values (CURRENT_TIMESTAMP),(CURRENT_TIMESTAMP),(CURRENT_TIMESTAMP)"
done
sql_dml_generator="
while ( 1 = 1 )
begin
${_sql_dml_body}
WAITFOR DELAY '00:00:${DML_INTERVAL_SEC}'
end
go
"
fi

db_replication_cleanup() {
    local GATEWAY_PIPELINE_ID=${1:${GATEWAY_PIPELINE_ID}}
    echo "db clean up after pipeline stop $GATEWAY_PIPELINE_ID"    
}
export -f db_replication_cleanup

# #############################################################################

# connect to master catalog (SSOT: TEST_DB_CONNECT + SQLCLI)
DB_EXIT_ON_ERROR=PRINT_EXIT DB_USERNAME="$DBA_USERNAME" DB_PASSWORD="$DBA_PASSWORD" DB_CATALOG=master TEST_DB_CONNECT

# #############################################################################
# create user login (must run against master)

DB_EXIT_ON_ERROR=PRINT_EXIT DB_CATALOG=master SQLCLI_DBA <<EOF
CREATE LOGIN ${USER_USERNAME} WITH PASSWORD = '${USER_PASSWORD}'
go
alter login ${USER_USERNAME} with password = '${USER_PASSWORD}'
go
CREATE USER ${USER_USERNAME} FOR LOGIN ${USER_USERNAME} WITH DEFAULT_SCHEMA=dbo
go
EOF

# connect to master as a user
DB_EXIT_ON_ERROR=PRINT_EXIT DB_USERNAME="$USER_USERNAME" DB_PASSWORD="$USER_PASSWORD" DB_CATALOG=master TEST_DB_CONNECT

# #############################################################################
# create user in the catalog

DB_EXIT_ON_ERROR=PRINT_EXIT DB_USERNAME="$DBA_USERNAME" DB_PASSWORD="$DBA_PASSWORD" DB_CATALOG="$DB_CATALOG" SQLCLI <<EOF
CREATE USER ${USER_USERNAME} FOR LOGIN ${USER_USERNAME} WITH DEFAULT_SCHEMA=dbo
go
ALTER ROLE db_owner ADD MEMBER ${USER_USERNAME}
go
ALTER ROLE db_ddladmin ADD MEMBER ${USER_USERNAME}
go
EOF

# connect to $DB_CATALOG as a user
DB_EXIT_ON_ERROR=PRINT_EXIT DB_USERNAME="$USER_USERNAME" DB_PASSWORD="$USER_PASSWORD" DB_CATALOG="$DB_CATALOG" TEST_DB_CONNECT

# #############################################################################

# database enable / disable CT

set_ct_on_catalog() {

case "${CDC_CT_MODE}" in 
"BOTH"|"CT") 

DB_EXIT_ON_ERROR=PRINT_EXIT DB_USERNAME="$DBA_USERNAME" DB_PASSWORD="$DBA_PASSWORD" DB_CATALOG="$DB_CATALOG" SQLCLI <<EOF
if exists (select * from sys.change_tracking_databases where database_id=db_id())
    BEGIN
        select 'CT already enabled'
    END
else
    BEGIN
        select 'CT enabled on database';
        exec ('ALTER DATABASE $DB_CATALOG SET CHANGE_TRACKING = ON (CHANGE_RETENTION = 3 DAYS, AUTO_CLEANUP = ON)');
    END 
go
EOF

echo -e "SET NOCOUNT ON\ngo\n select * from sys.change_tracking_databases where database_id=db_id()" | DB_USERNAME="$DBA_USERNAME" DB_PASSWORD="$DBA_PASSWORD" DB_CATALOG="$DB_CATALOG" SQLCLI
if [[ -s /tmp/sqlcmd_stdout.$$ ]]; then echo "ct db enable ok $DB_CATALOG catalog $DB_HOST_FQDN,${DB_PORT} $DBA_USERNAME"; 
else cat /tmp/sqlcmd_stdout.$$ /tmp/sqlcmd_stderr.$$
    return 1
fi

;;
*)

DB_USERNAME="$DBA_USERNAME" DB_PASSWORD="$DBA_PASSWORD" DB_CATALOG="$DB_CATALOG" SQLCLI <<EOF
-- ok to fail if table does not exist 
ALTER TABLE [${DB_SCHEMA}].[intpk] disable CHANGE_TRACKING
go
ALTER TABLE [${DB_SCHEMA_SCH}].[intpk_sch] disable CHANGE_TRACKING
go
    
if not exists (select * from sys.change_tracking_databases where database_id=db_id())
    BEGIN
        select 'CT already disabled'
    END
else
    BEGIN
        select 'CT disable on database';
        exec ('ALTER DATABASE $DB_CATALOG SET CHANGE_TRACKING = OFF;
');
    END 
go
EOF

echo -e "SET NOCOUNT ON\ngo\n select * from sys.change_tracking_databases where database_id=db_id()" | DB_USERNAME="$DBA_USERNAME" DB_PASSWORD="$DBA_PASSWORD" DB_CATALOG="$DB_CATALOG" SQLCLI
if [[ ! -s /tmp/sqlcmd_stdout.$$ ]]; then echo "ct db disable ok $DB_CATALOG catalog $DB_HOST_FQDN,${DB_PORT} $DBA_USERNAME"; 
else
    echo "ct db disable not ok $DB_CATALOG catalog $DB_HOST_FQDN,${DB_PORT} $DBA_USERNAME"
    cat /tmp/sqlcmd_stdout.$$ /tmp/sqlcmd_stderr.$$
    return 1 
fi

esac
}

# #############################################################################

# database enable / disable CDC 

set_cdc_on_catalog() {
case "${CDC_CT_MODE}" in 
"BOTH"|"CDC") 
# NOCOUNT is required to fix Invalid cursor state, SQL state 24000 in SQLExecDirect
DB_EXIT_ON_ERROR=PRINT_EXIT DB_USERNAME="$DBA_USERNAME" DB_PASSWORD="$DBA_PASSWORD" DB_CATALOG="$DB_CATALOG" SQLCLI <<EOF
SET NOCOUNT ON
go
if exists (select name, is_cdc_enabled from sys.databases where name=db_name() and is_cdc_enabled=1)
    BEGIN
        select 'CDC already enabled'
    END
else
  BEGIN
    select 'CDC enabled on database'
  END
go
-- vm and azure sql
if not exists (select name, is_cdc_enabled from sys.databases where name=db_name() and is_cdc_enabled=1)
  EXEC sys.sp_cdc_enable_db
go
-- GCP CloudSQL SQL Server
if not exists (select name, is_cdc_enabled from sys.databases where name=db_name() and is_cdc_enabled=1)
  EXEC msdb.dbo.gcloudsql_cdc_enable_db '$DB_CATALOG'
go
-- AWS RDS SQL Server
if not exists (select name, is_cdc_enabled from sys.databases where name=db_name() and is_cdc_enabled=1)
  EXEC msdb.dbo.rds_cdc_enable_db '$DB_CATALOG' 
go
EOF

echo -e "SET NOCOUNT ON\ngo\n select name, is_cdc_enabled from sys.databases where name=db_name() and is_cdc_enabled=1" | DB_USERNAME="$DBA_USERNAME" DB_PASSWORD="$DBA_PASSWORD" DB_CATALOG="$DB_CATALOG" SQLCLI
if [[ -s /tmp/sqlcmd_stdout.$$ ]]; then echo "cdc db enabled ok $DB_CATALOG catalog $DB_HOST_FQDN,${DB_PORT} $DBA_USERNAME"; 
else cat /tmp/sqlcmd_stdout.$$ /tmp/sqlcmd_stderr.$$
    return 1
fi

;;
*)

DB_USERNAME="$DBA_USERNAME" DB_PASSWORD="$DBA_PASSWORD" DB_CATALOG="$DB_CATALOG" SQLCLI <<EOF
-- ok to fail if table does not exist 
EXEC sys.sp_cdc_disable_table @source_schema = N'${DB_SCHEMA}', @source_name = N'dtix', @capture_instance = N'all'
go
EXEC sys.sp_cdc_disable_table @source_schema = N'${DB_SCHEMA}', @source_name = N'strpk', @capture_instance = N'all'
go
EXEC sys.sp_cdc_disable_table @source_schema = N'${DB_SCHEMA_SCH}', @source_name = N'dtix_sch', @capture_instance = N'all'
go
EXEC sys.sp_cdc_disable_table @source_schema = N'${DB_SCHEMA_SCH}', @source_name = N'strpk_sch', @capture_instance = N'all'
go

if exists (select name, is_cdc_enabled from sys.databases where name=db_name() and is_cdc_enabled=0)
    BEGIN
        select 'CDC already disabled'
    END
else
  BEGIN
    select 'CDC disable on database'
  END
go
-- vm and azure sql
if not exists (select name, is_cdc_enabled from sys.databases where name=db_name() and is_cdc_enabled=0)
  EXEC sys.sp_cdc_disable_db
go
-- GCP CloudSQL SQL Server
if not exists (select name, is_cdc_enabled from sys.databases where name=db_name() and is_cdc_enabled=0)
  EXEC msdb.dbo.gcloudsql_cdc_disable_db '$DB_CATALOG'
go
-- AWS RDS SQL Server
if not exists (select name, is_cdc_enabled from sys.databases where name=db_name() and is_cdc_enabled=0)
  EXEC msdb.dbo.rds_cdc_disable_db '$DB_CATALOG' 
go
EOF

echo -e "SET NOCOUNT ON\ngo\n select name, is_cdc_enabled from sys.databases where name=db_name() and is_cdc_enabled=0" | DB_USERNAME="$DBA_USERNAME" DB_PASSWORD="$DBA_PASSWORD" DB_CATALOG="$DB_CATALOG" SQLCLI
if [[ -s /tmp/sqlcmd_stdout.$$ ]]; then echo "cdc db disabled ok $DB_CATALOG catalog $DB_HOST_FQDN,${DB_PORT} $DBA_USERNAME"; 
else 
    echo -e "\n\nERROR: CDC COULD NOT BE ENABLED. CHANGING TO CT ONLY MODE\n\n"
    CDC_CT_MODE=CT
    cat /tmp/sqlcmd_stdout.$$ /tmp/sqlcmd_stderr.$$
fi
;;

esac
}

set_repl_on_catalog() {
    set_ct_on_catalog
    set_cdc_on_catalog
}
set_repl_on_catalog

# #############################################################################

# enable schema evolution

_SQLSERVER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-.}")" && pwd)"
export _SQLSERVER_DIR
_LFC_REPO_ROOT="${_LFC_REPO_ROOT:-$(cd "${_SQLSERVER_DIR}/.." && pwd)}"
export _LFC_REPO_ROOT

echo "enabling schema evolution"

set_sch_evo() {
    local ddl_script
    case "${CDC_CT_MODE}" in
    "BOTH"|"CDC")
        ddl_script="${_SQLSERVER_DIR}/ddl_support_objects.sql"
        ;;
    "CT")
        ddl_script="${_SQLSERVER_DIR}/deprecated_ddl_support_objects_ct_only.sql"
        ;;
    *)
        echo "CDC_CT_MODE=${CDC_CT_MODE} must be BOTH, CDC, or CT" >&2
        return 1
        ;;
    esac

    if [[ ! -s "$ddl_script" ]]; then
        echo "ERROR: missing or empty $ddl_script" >&2
        return 1
    fi

    echo "using $ddl_script with $CDC_CT_MODE"
    sed -e "s/SET \@replicationUser = '';/SET \@replicationUser = '${USER_USERNAME}';/" \
        -e "s/\@mode = '.*';/\@mode = '$CDC_CT_MODE';/" "$ddl_script" | \
    DB_EXIT_ON_ERROR=PRINT_EXIT DB_USERNAME="${DBA_USERNAME}" DB_PASSWORD="${DBA_PASSWORD}" \
        DB_CATALOG="${DB_CATALOG}" SQLCLI
}
export -f set_sch_evo
if ! set_sch_evo; then
    echo "ERROR: set_sch_evo failed" >&2
    return 1
fi

# Install Lakeflow utility objects (versioned; setup procs run after tables exist)
echo "installing utility_script (latest registered)"
DB_USERNAME="${DBA_USERNAME}" DB_PASSWORD="${DBA_PASSWORD}" DB_CATALOG="${DB_CATALOG}" \
  python3 "${_LFC_REPO_ROOT}/utils/sqlserver-utility-script.py" \
    --user "${USER_USERNAME}" \
    --install-only \
    --apply || return 1

# #############################################################################

# create schemas: DB_SCHEMA (per-table) + DB_SCHEMA_SCH (*_sch tables)

for _demo_schema in "${DB_SCHEMA}" "${DB_SCHEMA_SCH}"; do
DB_EXIT_ON_ERROR=PRINT_EXIT DB_CATALOG="${DB_CATALOG}" SQLCLI_USER <<EOF
create schema [${_demo_schema}]
go
EOF
done

# #############################################################################

# create tables

# Recreate strpk* so NEWID default applies (plain create would fail / keep old DDL)
for _sfx in "" "_sch"; do
  if [[ -z "${_sfx}" ]]; then
    _schema="${DB_SCHEMA}"
  else
    _schema="${DB_SCHEMA_SCH}"
  fi

  DB_CATALOG="${DB_CATALOG}" SQLCLI_USER <<EOF
IF OBJECT_ID(N'${_schema}.strpk${_sfx}', N'U') IS NOT NULL drop table [${_schema}].[strpk${_sfx}]
go
create table [${_schema}].[intpk${_sfx}] (pk int IDENTITY NOT NULL primary key, dt datetime)
go
create table [${_schema}].[strpk${_sfx}] (pk nvarchar(64) NOT NULL primary key DEFAULT CONVERT(varchar(36), NEWID()), dt datetime)
go
create table [${_schema}].[dtix${_sfx}] (dt datetime)
go
EOF

  if [[ "$INITIAL_SNAPSHOT_ROWS" -gt 0 ]]; then
    DB_CATALOG="${DB_CATALOG}" SQLCLI_USER <<EOF
IF OBJECT_ID(N'${_schema}.intpk${_sfx}', N'U') IS NOT NULL
    insert into [${_schema}].[intpk${_sfx}] (dt) values (CURRENT_TIMESTAMP),(CURRENT_TIMESTAMP), (CURRENT_TIMESTAMP)
go
IF OBJECT_ID(N'${_schema}.strpk${_sfx}', N'U') IS NOT NULL
    insert into [${_schema}].[strpk${_sfx}] (dt) values (CURRENT_TIMESTAMP),(CURRENT_TIMESTAMP),(CURRENT_TIMESTAMP)
go
IF OBJECT_ID(N'${_schema}.dtix${_sfx}', N'U') IS NOT NULL
    insert into [${_schema}].[dtix${_sfx}] (dt) values (CURRENT_TIMESTAMP),(CURRENT_TIMESTAMP),(CURRENT_TIMESTAMP)
go
EOF

    echo -e "SET NOCOUNT ON\ngo\n select max(pk) from [${_schema}].[intpk${_sfx}]" | DB_CATALOG="${DB_CATALOG}" SQLCLI_USER
    if [[ -s /tmp/sqlcmd_stdout.$$ ]]; then echo "table intpk${_sfx} ok ${_schema}"; else cat /tmp/sqlcmd_stdout.$$ /tmp/sqlcmd_stderr.$$; return 1; fi
    echo -e "SET NOCOUNT ON\ngo\n select max(pk) from [${_schema}].[strpk${_sfx}]" | DB_CATALOG="${DB_CATALOG}" SQLCLI_USER
    if [[ -s /tmp/sqlcmd_stdout.$$ ]]; then echo "table strpk${_sfx} ok ${_schema}"; else cat /tmp/sqlcmd_stdout.$$ /tmp/sqlcmd_stderr.$$; return 1; fi
    echo -e "SET NOCOUNT ON\ngo\n select top 1 dt from [${_schema}].[dtix${_sfx}]" | DB_CATALOG="${DB_CATALOG}" SQLCLI_USER
    if [[ -s /tmp/sqlcmd_stdout.$$ ]]; then echo "table dtix${_sfx} ok ${_schema}"; else cat /tmp/sqlcmd_stdout.$$ /tmp/sqlcmd_stderr.$$; return 1; fi
  fi
done

# #############################################################################

# Run Lakeflow utility setup for both schemas
for _demo_schema in "${DB_SCHEMA}" "${DB_SCHEMA_SCH}"; do
echo "running utility_script setup for SCHEMAS:${_demo_schema} mode=${CDC_CT_MODE}"
DB_USERNAME="${DBA_USERNAME}" DB_PASSWORD="${DBA_PASSWORD}" DB_CATALOG="${DB_CATALOG}" \
  python3 "${_LFC_REPO_ROOT}/utils/sqlserver-utility-script.py" \
    --user "${USER_USERNAME}" \
    --tables "SCHEMAS:${_demo_schema}" \
    --capture-mode "${CDC_CT_MODE}" \
    --setup-only \
    --apply || return 1
done

# #############################################################################

# enable CT / CDC on tables

set_repl_on_table() {
if [[ "${CDC_CT_MODE}" =~ ^(BOTH|CT)$  ]]; then
DB_CATALOG="${DB_CATALOG}" SQLCLI_USER <<EOF
    ALTER TABLE [${DB_SCHEMA}].[intpk] ENABLE CHANGE_TRACKING WITH (TRACK_COLUMNS_UPDATED = ON)
go
    ALTER TABLE [${DB_SCHEMA_SCH}].[intpk_sch] ENABLE CHANGE_TRACKING WITH (TRACK_COLUMNS_UPDATED = ON)
go
EOF
echo -e "SET NOCOUNT ON\ngo\n select db_name() TABLE_CAT, schema_name(t.schema_id) TABLE_SCHEM, t.name TABLE_NAME  from sys.change_tracking_tables ctt left join sys.tables t on ctt.object_id = t.object_id where t.schema_id in (schema_id('${DB_SCHEMA}'), schema_id('${DB_SCHEMA_SCH}'))" | DB_CATALOG="${DB_CATALOG}" SQLCLI_USER
if [[ -s /tmp/sqlcmd_stdout.$$ ]]; then echo "ct table enabled ok"; else cat /tmp/sqlcmd_stdout.$$ /tmp/sqlcmd_stderr.$$; return 1; fi
else
echo "ct table enable skipped (CDC_CT_MODE=${CDC_CT_MODE})"
fi

if [[ "${CDC_CT_MODE}" =~ ^(BOTH|CDC)$  ]]; then
DB_CATALOG="${DB_CATALOG}" SQLCLI_USER <<EOF
EXEC sys.sp_cdc_enable_table @source_schema = N'${DB_SCHEMA}', @source_name = N'dtix', @role_name = NULL, @supports_net_changes = 0
go
EXEC sys.sp_cdc_enable_table @source_schema = N'${DB_SCHEMA}', @source_name = N'strpk', @role_name = NULL, @supports_net_changes = 0
go
EXEC sys.sp_cdc_enable_table @source_schema = N'${DB_SCHEMA_SCH}', @source_name = N'dtix_sch', @role_name = NULL, @supports_net_changes = 0
go
EXEC sys.sp_cdc_enable_table @source_schema = N'${DB_SCHEMA_SCH}', @source_name = N'strpk_sch', @role_name = NULL, @supports_net_changes = 0
go
EOF
echo -e "SET NOCOUNT ON\ngo\n select db_name() TABLE_CAT, s.name TABLE_SCHEM, t.name as TABLE_NAME from sys.tables t left join sys.schemas s on t.schema_id = s.schema_id where t.is_tracked_by_cdc=1 and t.schema_id in (schema_id('${DB_SCHEMA}'), schema_id('${DB_SCHEMA_SCH}'))" | DB_CATALOG="${DB_CATALOG}" SQLCLI_USER
if [[ -s /tmp/sqlcmd_stdout.$$ ]]; then echo "cdc table enabled ok"; else cat /tmp/sqlcmd_stdout.$$ /tmp/sqlcmd_stderr.$$; return 1; fi
else
echo "cdc table enable skipped (CDC_CT_MODE=${CDC_CT_MODE})"
fi
}

set_repl_on_table

# #############################################################################

# #############################################################################

echo -e "Run the lakeflow connect steps:

source  <(curl -s -L https://raw.githubusercontent.com/rsleedbx/lakeflow_connect/refs/heads/main/03_lakeflow_connect_demo.sh)
"