#!/usr/bin/env bash

# error out when undeclared variable is used
set -u 

# must be sourced for exports to continue to the next script
if [ "$0" == "$BASH_SOURCE" ]; then
  echo "Script is being executed directly. Please run as source $0"
  return 1
fi

# #############################################################################

# connect to master catalog
if ! test_db_connect "$DBA_USERNAME" "$DBA_PASSWORD" "$DB_HOST_FQDN" "$DB_PORT" "master"; then
    cat /tmp/select1_stdout.$$ /tmp/select1_stderr.$$; return 1;
fi    

# #############################################################################
# create user login

cat <<EOF | sqlcmd -S ${DB_HOST_FQDN},${DB_PORT} -U "${DBA_USERNAME}" -P "${DBA_PASSWORD}" -C -l 60 >/tmp/sqlcmd_stdout.$$ 2>/tmp/sqlcmd_stderr.$$
CREATE LOGIN ${USER_USERNAME} WITH PASSWORD = '${USER_PASSWORD}'
go
alter login ${USER_USERNAME} with password = '${USER_PASSWORD}'
go
-- gcp does not allow user login
CREATE USER ${USER_USERNAME} FOR LOGIN ${USER_USERNAME} WITH DEFAULT_SCHEMA=dbo
go
EOF

# connect to master as a user
if ! test_db_connect "$USER_USERNAME" "$USER_PASSWORD" "$DB_HOST_FQDN" "$DB_PORT" "master"; then
    cat /tmp/select1_stdout.$$ /tmp/select1_stderr.$$; return 1;
fi   

# #############################################################################
# create user in the catalog

cat <<EOF | sqlcmd -d ${DB_CATALOG} -S ${DB_HOST_FQDN},${DB_PORT} -U "${DBA_USERNAME}" -P "${DBA_PASSWORD}" -C -l 60  >/tmp/sqlcmd_stdout.$$ 2>/tmp/sqlcmd_stderr.$$
CREATE USER ${USER_USERNAME} FOR LOGIN ${USER_USERNAME} WITH DEFAULT_SCHEMA=dbo
go
ALTER ROLE db_owner ADD MEMBER ${USER_USERNAME}
go
ALTER ROLE db_ddladmin ADD MEMBER ${USER_USERNAME}
go
EOF

# connect to $DB_CATALOG as a user
if ! test_db_connect "$USER_USERNAME" "$USER_PASSWORD" "$DB_HOST_FQDN" "$DB_PORT" "$DB_CATALOG"; then
    cat /tmp/select1_stdout.$$ /tmp/select1_stderr.$$; return 1;
fi   

# #############################################################################

# database enable / disable CT

case "${CDC_CT_MODE}" in 
"BOTH"|"CT") 

cat <<EOF | sqlcmd -d ${DB_CATALOG} -S ${DB_HOST_FQDN},${DB_PORT} -U "${DBA_USERNAME}" -P "${DBA_PASSWORD}" -C -l 60 >/tmp/sqlcmd_stdout.$$ 2>/tmp/sqlcmd_stderr.$$
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

echo -e "SET NOCOUNT ON\ngo\n select * from sys.change_tracking_databases where database_id=db_id()" | sqlcmd -S $DB_HOST_FQDN,${DB_PORT} -U "$DBA_USERNAME" -P "$DBA_PASSWORD" -d "$DB_CATALOG" -C -l 60 -h -1  >/tmp/sqlcmd_stdout.$$ 2>/tmp/sqlcmd_stderr.$$
if [[ -s /tmp/sqlcmd_stdout.$$ ]]; then echo "ct db enable ok $DB_CATALOG catalog $DB_HOST_FQDN,${DB_PORT} $DBA_USERNAME"; 
else cat /tmp/sqlcmd_stdout.$$ /tmp/sqlcmd_stderr.$$; return 1; fi

;;
*)

cat <<EOF | sqlcmd -d ${DB_CATALOG} -S ${DB_HOST_FQDN},${DB_PORT} -U "${DBA_USERNAME}" -P "${DBA_PASSWORD}" -C -l 60 >/tmp/sqlcmd_stdout.$$ 2>/tmp/sqlcmd_stderr.$$
-- ok to fail if table does not exist 
ALTER TABLE [${DB_SCHEMA}].[intpk] disable CHANGE_TRACKING
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

echo -e "SET NOCOUNT ON\ngo\n select * from sys.change_tracking_databases where database_id=db_id()" | sqlcmd -S $DB_HOST_FQDN,${DB_PORT} -U "$DBA_USERNAME" -P "$DBA_PASSWORD" -d "$DB_CATALOG" -C -l 60 -h -1  >/tmp/sqlcmd_stdout.$$ 2>/tmp/sqlcmd_stderr.$$
if [[ ! -s /tmp/sqlcmd_stdout.$$ ]]; then echo "ct db disable ok $DB_CATALOG catalog $DB_HOST_FQDN,${DB_PORT} $DBA_USERNAME"; 
else
    echo "ct db disable not ok $DB_CATALOG catalog $DB_HOST_FQDN,${DB_PORT} $DBA_USERNAME"
    cat /tmp/sqlcmd_stdout.$$ /tmp/sqlcmd_stderr.$$; return 1; 
fi

esac

# #############################################################################

# database enable / disable CDC 

case "${CDC_CT_MODE}" in 
"BOTH"|"CDC") 
cat <<EOF | sqlcmd -d ${DB_CATALOG} -S ${DB_HOST_FQDN},${DB_PORT} -U "${DBA_USERNAME}" -P "${DBA_PASSWORD}" -C -l 60 >/tmp/sqlcmd_stdout.$$ 2>/tmp/sqlcmd_stderr.$$
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

echo -e "SET NOCOUNT ON\ngo\n select name, is_cdc_enabled from sys.databases where name=db_name() and is_cdc_enabled=1" | sqlcmd -S $DB_HOST_FQDN,${DB_PORT} -U "$DBA_USERNAME" -P "$DBA_PASSWORD" -d "$DB_CATALOG" -C -l 60 -h -1  >/tmp/sqlcmd_stdout.$$ 2>/tmp/sqlcmd_stderr.$$
if [[ -s /tmp/sqlcmd_stdout.$$ ]]; then echo "cdc db enabled ok $DB_CATALOG catalog $DB_HOST_FQDN,${DB_PORT} $DBA_USERNAME"; 
else cat /tmp/sqlcmd_stdout.$$ /tmp/sqlcmd_stderr.$$; return 1; fi

;;
*)

cat <<EOF | sqlcmd -d ${DB_CATALOG} -S ${DB_HOST_FQDN},${DB_PORT} -U "${DBA_USERNAME}" -P "${DBA_PASSWORD}" -C -l 60 >/tmp/sqlcmd_stdout.$$ 2>/tmp/sqlcmd_stderr.$$
-- ok to fail if table does not exist 
EXEC sys.sp_cdc_disable_table @source_schema = N'${DB_SCHEMA}', @source_name = N'dtix', @capture_instance = N'all'
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

echo -e "SET NOCOUNT ON\ngo\n select name, is_cdc_enabled from sys.databases where name=db_name() and is_cdc_enabled=0" | sqlcmd -S $DB_HOST_FQDN,${DB_PORT} -U "$DBA_USERNAME" -P "$DBA_PASSWORD" -d "$DB_CATALOG" -C -l 60 -h -1  >/tmp/sqlcmd_stdout.$$ 2>/tmp/sqlcmd_stderr.$$
if [[ -s /tmp/sqlcmd_stdout.$$ ]]; then echo "cdc db disabled ok $DB_CATALOG catalog $DB_HOST_FQDN,${DB_PORT} $DBA_USERNAME"; 
else cat /tmp/sqlcmd_stdout.$$ /tmp/sqlcmd_stderr.$$; return 1; fi
;;

esac

# #############################################################################

# enable schema evolution

case "${CDC_CT_MODE}" in 
"BOTH"|"CDC") 
    if [[ -f ./ddl_support_objects.sql ]]; then
    cat ./ddl_support_objects.sql | \
    sed -e "s/SET \@replicationUser = '';/SET \@replicationUser = '${USER_USERNAME}';/" -e "s/\@mode = '.*';/\@mode = '$CDC_CT_MODE';/" | \
    sqlcmd -d "${DB_CATALOG}" -S ${DB_HOST_FQDN},${DB_PORT} -U "${DBA_USERNAME}" -P "${DBA_PASSWORD}" -C -l 60 
    else
    wget -qO- https://raw.githubusercontent.com/rsleedbx/lakeflow_connect/refs/heads/main/sqlserver/ddl_support_objects.sql | \
    sed -e "s/SET \@replicationUser = '';/SET \@replicationUser = '${USER_USERNAME}';/" -e "s/\@mode = '.*';/\@mode = '$CDC_CT_MODE';/" | \
    sqlcmd -d "${DB_CATALOG}" -S ${DB_HOST_FQDN},${DB_PORT} -U "${DBA_USERNAME}" -P "${DBA_PASSWORD}" -C -l 60 
    fi
    ;;
"CT") 
    if [[ -f ./ddl_support_objects_ct_only.sql ]]; then
    cat ./ddl_support_objects_ct_only.sql | \
    sed -e "s/SET \@replicationUser = '';/SET \@replicationUser = '${USER_USERNAME}';/" -e "s/\@mode = '.*';/\@mode = '$CDC_CT_MODE';/" | \
    sqlcmd -d "${DB_CATALOG}" -S ${DB_HOST_FQDN},${DB_PORT} -U "${DBA_USERNAME}" -P "${DBA_PASSWORD}" -C -l 60 
    else
    wget -qO- https://raw.githubusercontent.com/rsleedbx/lakeflow_connect/refs/heads/main/sqlserver/ddl_support_objects_ct_only.sql | \
    sed -e "s/SET \@replicationUser = '';/SET \@replicationUser = '${USER_USERNAME}';/" -e "s/\@mode = '.*';/\@mode = '$CDC_CT_MODE';/" | \
    sqlcmd -d "${DB_CATALOG}" -S ${DB_HOST_FQDN},${DB_PORT} -U "${DBA_USERNAME}" -P "${DBA_PASSWORD}" -C -l 60 
    fi
    ;;
*)
    echo "CDC_CT_MODE=${CDC_CT_MODE} must be BOTH or CT"
    return 1
    ;;
esac

# #############################################################################

# create tables

cat <<EOF | sqlcmd -d ${DB_CATALOG} -S ${DB_HOST_FQDN},${DB_PORT} -U "${USER_USERNAME}" -P "${USER_PASSWORD}" -C -l 60 >/tmp/sqlcmd_stdout.$$ 2>/tmp/sqlcmd_stderr.$$
create schema [${DB_SCHEMA}]
go
create table [${DB_SCHEMA}].[intpk] (pk int IDENTITY NOT NULL primary key, dt datetime)
go
create table [${DB_SCHEMA}].[dtix] (dt datetime)
go
EOF

cat <<EOF | sqlcmd -d ${DB_CATALOG} -S ${DB_HOST_FQDN},${DB_PORT} -U "${USER_USERNAME}" -P "${USER_PASSWORD}" -C -l 60 >/tmp/sqlcmd_stdout.$$ 2>/tmp/sqlcmd_stderr.$$
IF OBJECT_ID(N'${DB_SCHEMA}.intpx', N'U') IS NOT NULL
    insert into [${DB_SCHEMA}].[intpk] (dt) values (CURRENT_TIMESTAMP),(CURRENT_TIMESTAMP), (CURRENT_TIMESTAMP)
go
IF OBJECT_ID(N'${DB_SCHEMA}.dtix', N'U') IS NOT NULL
    insert into [${DB_SCHEMA}].[dtix] (dt) values (CURRENT_TIMESTAMP),(CURRENT_TIMESTAMP),(CURRENT_TIMESTAMP)
go
EOF

echo -e "SET NOCOUNT ON\ngo\n select max(pk) from [${DB_SCHEMA}].[intpk]" | sqlcmd -d ${DB_CATALOG} -S ${DB_HOST_FQDN},${DB_PORT} -U "${USER_USERNAME}" -P "${USER_PASSWORD}" -C -l 60 -h -1 >/tmp/select_stdout.$$ 2>/tmp/select_stderr.$$
if [[ -s /tmp/select_stdout.$$ ]]; then echo "table intpk ok $DB_SCHEMA schema $DB_HOST_FQDN,${DB_PORT} $DBA_USERNAME"; 
else cat /tmp/sqlcmd_stdout.$$ /tmp/sqlcmd_stderr.$$; return 1; fi

echo -e "SET NOCOUNT ON\ngo\n select top 1 dt from [${DB_SCHEMA}].[dtix]" | sqlcmd -d ${DB_CATALOG} -S ${DB_HOST_FQDN},${DB_PORT} -U "${USER_USERNAME}" -P "${USER_PASSWORD}" -C -l 60 -h -1 >/tmp/select_stdout.$$ 2>/tmp/select_stderr.$$
if [[ -s /tmp/select_stdout.$$ ]]; then echo "table dtix ok $DB_SCHEMA schema $DB_HOST_FQDN,${DB_PORT} $DBA_USERNAME"; 
else cat /tmp/sqlcmd_stdout.$$ /tmp/sqlcmd_stderr.$$; return 1; fi

# #############################################################################

# enable CT on  tables

if [[ "${CDC_CT_MODE}" =~ ^(BOTH|CT)$  ]]; then 
cat <<EOF | sqlcmd -d ${DB_CATALOG} -S ${DB_HOST_FQDN},${DB_PORT} -U "${USER_USERNAME}" -P "${USER_PASSWORD}" -C -l 60 >/tmp/sqlcmd_stdout.$$ 2>/tmp/sqlcmd_stderr.$$
    ALTER TABLE [${DB_SCHEMA}].[intpk] ENABLE CHANGE_TRACKING WITH (TRACK_COLUMNS_UPDATED = ON) 
go
EOF

echo -e "SET NOCOUNT ON\ngo\n select db_name() TABLE_CAT, schema_name(t.schema_id) TABLE_SCHEM, t.name TABLE_NAME  from sys.change_tracking_tables ctt left join sys.tables t on ctt.object_id = t.object_id where t.schema_id=schema_id('${DB_SCHEMA}')" | sqlcmd -d ${DB_CATALOG} -S ${DB_HOST_FQDN},${DB_PORT} -U "${USER_USERNAME}" -P "${USER_PASSWORD}" -C -l 60 -h -1 >/tmp/select_stdout.$$ 2>/tmp/select_stderr.$$
if [[ -s /tmp/select_stdout.$$ ]]; then echo "ct table enabled ok $DB_SCHEMA schema $DB_HOST_FQDN,${DB_PORT} $DBA_USERNAME"; 
else cat /tmp/sqlcmd_stdout.$$ /tmp/sqlcmd_stderr.$$; return 1; fi

else

echo -e "SET NOCOUNT ON\ngo\n select db_name() TABLE_CAT, schema_name(t.schema_id) TABLE_SCHEM, t.name TABLE_NAME  from sys.change_tracking_tables ctt left join sys.tables t on ctt.object_id = t.object_id where t.schema_id=schema_id('${DB_SCHEMA}')" | sqlcmd -d ${DB_CATALOG} -S ${DB_HOST_FQDN},${DB_PORT} -U "${USER_USERNAME}" -P "${USER_PASSWORD}" -C -l 60 -h -1 >/tmp/select_stdout.$$ 2>/tmp/select_stderr.$$
if [[ ! -s /tmp/select_stdout.$$ ]]; then echo "ct table disabled ok $DB_SCHEMA schema $DB_HOST_FQDN,${DB_PORT} $DBA_USERNAME"; 
else cat /tmp/sqlcmd_stdout.$$ /tmp/sqlcmd_stderr.$$; return 1; fi

fi



if [[ "${CDC_CT_MODE}" =~ ^(BOTH|CDC)$  ]]; then 

cat <<EOF | sqlcmd -d ${DB_CATALOG} -S ${DB_HOST_FQDN},${DB_PORT} -U "${USER_USERNAME}" -P "${USER_PASSWORD}" -C -l 60 >/tmp/sqlcmd_stdout.$$ 2>/tmp/sqlcmd_stderr.$$
create table [${DB_SCHEMA}].[dtix] (dt datetime)
go
EXEC sys.sp_cdc_enable_table @source_schema = N'${DB_SCHEMA}', @source_name = N'dtix', @role_name = NULL, @supports_net_changes = 0
go
EOF

echo -e "SET NOCOUNT ON\ngo\n select db_name() TABLE_CAT, s.name TABLE_SCHEM, t.name as TABLE_NAME from sys.tables t left join sys.schemas s on t.schema_id = s.schema_id where t.is_tracked_by_cdc=1 and t.schema_id=schema_id('${DB_SCHEMA}')" | sqlcmd -d ${DB_CATALOG} -S ${DB_HOST_FQDN},${DB_PORT} -U "${USER_USERNAME}" -P "${USER_PASSWORD}" -C -l 60 -h -1 >/tmp/select_stdout.$$ 2>/tmp/select_stderr.$$
if [[ -s /tmp/select_stdout.$$ ]]; then echo "cdc table enabled ok $DB_SCHEMA schema $DB_HOST_FQDN,${DB_PORT} $DBA_USERNAME"; 
else cat /tmp/sqlcmd_stdout.$$ /tmp/sqlcmd_stderr.$$; return 1; fi

else

echo -e "SET NOCOUNT ON\ngo\n select db_name() TABLE_CAT, s.name TABLE_SCHEM, t.name as TABLE_NAME from sys.tables t left join sys.schemas s on t.schema_id = s.schema_id where t.is_tracked_by_cdc=1 and t.schema_id=schema_id('${DB_SCHEMA}')" | sqlcmd -d ${DB_CATALOG} -S ${DB_HOST_FQDN},${DB_PORT} -U "${USER_USERNAME}" -P "${USER_PASSWORD}" -C -l 60 -h -1 >/tmp/select_stdout.$$ 2>/tmp/select_stderr.$$
if [[ ! -s /tmp/select_stdout.$$ ]]; then echo "cdc table disabled ok $DB_SCHEMA schema $DB_HOST_FQDN,${DB_PORT} $DBA_USERNAME"; 
else cat /tmp/sqlcmd_stdout.$$ /tmp/sqlcmd_stderr.$$; return 1; fi

fi

# #############################################################################
