#!/usr/bin/env bash

# must be sourced for exports to continue to the next script
if [ "$0" == "$BASH_SOURCE" ]; then
  echo "Script is being executed directly. Please run as source $0"
  return 1
fi

if [[ -z $DBX_USERNAME ]] || \
 [[ -z $WHOAMI ]] || \
 [[ -z $EXPIRE_DATE ]] || \
 [[ -z $DB_CATALOG ]] || \
 [[ -z $DB_SCHEMA ]] || \
 [[ -z $DB_HOST ]] || \
 [[ -z $DB_PORT ]] || \
 [[ -z $DBA_PASSWORD ]] || \
 [[ -z $USER_PASSWORD ]] || \
 [[ -z $DBA_USERNAME ]] || \
 [[ -z $USER_USERNAME ]] || \
 [[ -z $DB_HOST ]] || \
 [[ -z $DB_HOST_FQDN ]]; then 
    if [[ -f ./00_lakeflow_connect_env.sh ]]; then
        source ./00_lakeflow_connect_env.sh
    else
        source <(curl -s -L https://raw.githubusercontent.com/rsleedbx/lakeflow_connect/refs/heads/sqlserver/sqlserver/00_lakeflow_connect_env.sh)
    fi
fi

# #############################################################################

# connect to master catalog
echo "select 1" | sqlcmd -S $DB_HOST_FQDN,${DB_PORT} -U "${DBA_USERNAME}" -P "${DBA_PASSWORD}" -C -l 60 >/tmp/select1_stdout.$$ 2>/tmp/select1_stderr.$$
if [[ $? == 0 ]]; then echo "Connect ok master catalog $DB_HOST_FQDN,${DB_PORT} $DBA_USERNAME"; 
else cat /tmp/select1_stdout.$$ /tmp/select1_stderr.$$; return 1; fi

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

# update password save to secrets
SECRETS_USER_PASSWORD="$(databricks secrets get-secret ${SECRETS_SCOPE} USER_PASSWORD 2>/dev/null | jq -r .value | base64 --decode)"
if [[ "$SECRETS_USER_PASSWORD" != "$USER_PASSWORD" ]]; then
    echo "Updating secrets ${SECRETS_SCOPE}"
    databricks secrets create-scope ${SECRETS_SCOPE} 2>/dev/null 
    databricks secrets put-secret ${SECRETS_SCOPE} USER_PASSWORD --string-value "${USER_PASSWORD}"
    databricks secrets put-secret ${SECRETS_SCOPE} USER_USERNAME --string-value "${USER_USERNAME}"
fi

# connect to master as a user
echo "select 1" | sqlcmd -S $DB_HOST_FQDN,${DB_PORT} -U "$USER_USERNAME" -P "$USER_PASSWORD" -C -l 60 >/tmp/select1_stdout.$$ 2>/tmp/select1_stderr.$$
if [[ $? == 0 ]]; then echo "Connect ok master catalog $DB_HOST_FQDN,${DB_PORT} $USER_USERNAME"; 
else cat /tmp/sqlcmd_stdout.$$ /tmp/sqlcmd_stderr.$$; return 1; fi

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
echo "select 1" | sqlcmd -S $DB_HOST_FQDN,${DB_PORT} -U "$USER_USERNAME" -P "$USER_PASSWORD" -d "$DB_CATALOG" -C -l 60 >/tmp/sqlcmd_stdout.$$ 2>/tmp/sqlcmd_stderr.$$
if [[ $? == 0 ]]; then echo "Connect ok $DB_CATALOG catalog $DB_HOST_FQDN,${DB_PORT} $USER_USERNAME"; 
else cat /tmp/sqlcmd_stdout.$$ /tmp/sqlcmd_stderr.$$; return 1; fi

# #############################################################################

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
if [[ -s /tmp/sqlcmd_stdout.$$ ]]; then echo "ct ok $DB_CATALOG catalog $DB_HOST_FQDN,${DB_PORT} $DBA_USERNAME"; 
else cat /tmp/sqlcmd_stdout.$$ /tmp/sqlcmd_stderr.$$; return 1; fi

# #############################################################################

cat <<EOF | sqlcmd -d ${DB_CATALOG} -S ${DB_HOST_FQDN},${DB_PORT} -U "${DBA_USERNAME}" -P "${DBA_PASSWORD}" -C -l 60 >/tmp/sqlcmd_stdout.$$ 2>/tmp/sqlcmd_stderr.$$
if exists (select name, is_cdc_enabled from sys.databases where name=db_name() and is_cdc_enabled=1)
    BEGIN
        select 'CDC already enabled'
    END
else
  BEGIN
    select 'CD enabled on database'
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
if [[ -s /tmp/sqlcmd_stdout.$$ ]]; then echo "cdc ok $DB_CATALOG catalog $DB_HOST_FQDN,${DB_PORT} $DBA_USERNAME"; 
else cat /tmp/sqlcmd_stdout.$$ /tmp/sqlcmd_stderr.$$; return 1; fi


# #############################################################################

wget -qO- https://raw.githubusercontent.com/rsleedbx/lakeflow_connect/refs/heads/main/sqlserver/ddl_support_objects.sql | \
  sed "s/SET \@replicationUser = '';/SET \@replicationUser = '${USER_USERNAME}';/" | \
  sqlcmd -d "${DB_CATALOG}" -S ${DB_HOST_FQDN},${DB_PORT} -U "${DBA_USERNAME}" -P "${DBA_PASSWORD}" -C -l 60 

# #############################################################################

cat <<EOF | sqlcmd -d ${DB_CATALOG} -S ${DB_HOST_FQDN},${DB_PORT} -U "${USER_USERNAME}" -P "${USER_PASSWORD}" -C -l 60 >/tmp/sqlcmd_stdout.$$ 2>/tmp/sqlcmd_stderr.$$
create schema [${DB_SCHEMA}]
go
create table [${DB_SCHEMA}].[intpk] (pk int IDENTITY NOT NULL primary key, dt datetime)
go
ALTER TABLE [${DB_SCHEMA}].[intpk] ENABLE CHANGE_TRACKING WITH (TRACK_COLUMNS_UPDATED = ON) 
go
create table [${DB_SCHEMA}].[dtix] (dt datetime)
go
EXEC sys.sp_cdc_enable_table @source_schema = N'${DB_SCHEMA}', @source_name = N'dtix', @role_name = NULL, @supports_net_changes = 0
go
EOF


echo -e "SET NOCOUNT ON\ngo\n select db_name() TABLE_CAT, schema_name(t.schema_id) TABLE_SCHEM, t.name TABLE_NAME  from sys.change_tracking_tables ctt left join sys.tables t on ctt.object_id = t.object_id where t.schema_id=schema_id('${DB_SCHEMA}')" | sqlcmd -d ${DB_CATALOG} -S ${DB_HOST_FQDN},${DB_PORT} -U "${USER_USERNAME}" -P "${USER_PASSWORD}" -C -l 60 -h -1 >/tmp/select_stdout.$$ 2>/tmp/select_stderr.$$
if [[ -s /tmp/select_stdout.$$ ]]; then echo "ct ok $DB_SCHEMA schema $DB_HOST_FQDN,${DB_PORT} $DBA_USERNAME"; 
else cat /tmp/sqlcmd_stdout.$$ /tmp/sqlcmd_stderr.$$; return 1; fi


echo -e "SET NOCOUNT ON\ngo\n select db_name() TABLE_CAT, s.name TABLE_SCHEM, t.name as TABLE_NAME from sys.tables t left join sys.schemas s on t.schema_id = s.schema_id where t.is_tracked_by_cdc=1 and t.schema_id=schema_id('${DB_SCHEMA}')" | sqlcmd -d ${DB_CATALOG} -S ${DB_HOST_FQDN},${DB_PORT} -U "${USER_USERNAME}" -P "${USER_PASSWORD}" -C -l 60 -h -1 >/tmp/select_stdout.$$ 2>/tmp/select_stderr.$$
if [[ -s /tmp/select_stdout.$$ ]]; then echo "cdc ok $DB_SCHEMA schema $DB_HOST_FQDN,${DB_PORT} $DBA_USERNAME"; 
else cat /tmp/sqlcmd_stdout.$$ /tmp/sqlcmd_stderr.$$; return 1; fi

# #############################################################################

cat <<EOF | sqlcmd -d ${DB_CATALOG} -S ${DB_HOST_FQDN},${DB_PORT} -U "${USER_USERNAME}" -P "${USER_PASSWORD}" -C -l 60 >/tmp/sqlcmd_stdout.$$ 2>/tmp/sqlcmd_stderr.$$
insert into [${DB_SCHEMA}].[intpk] (dt) values (CURRENT_TIMESTAMP),(CURRENT_TIMESTAMP), (CURRENT_TIMESTAMP)
go
insert into [${DB_SCHEMA}].[dtix] (dt) values (CURRENT_TIMESTAMP),(CURRENT_TIMESTAMP),(CURRENT_TIMESTAMP)
go
delete from [${DB_SCHEMA}].[intpk] where pk=(select min(pk) from [${DB_SCHEMA}].[intpk])
go
update [${DB_SCHEMA}].[intpk] set dt=CURRENT_TIMESTAMP where pk=(select min(pk) from [${DB_SCHEMA}].[intpk])
go
EOF

echo -e "SET NOCOUNT ON\ngo\n select max(pk) from [${DB_SCHEMA}].[intpk]" | sqlcmd -d ${DB_CATALOG} -S ${DB_HOST_FQDN},${DB_PORT} -U "${USER_USERNAME}" -P "${USER_PASSWORD}" -C -l 60 -h -1 >/tmp/select_stdout.$$ 2>/tmp/select_stderr.$$
if [[ -s /tmp/select_stdout.$$ ]]; then echo "intpk ok $DB_SCHEMA schema $DB_HOST_FQDN,${DB_PORT} $DBA_USERNAME"; 
else cat /tmp/sqlcmd_stdout.$$ /tmp/sqlcmd_stderr.$$; return 1; fi

echo -e "SET NOCOUNT ON\ngo\n select top 1 dt from [${DB_SCHEMA}].[dtix]" | sqlcmd -d ${DB_CATALOG} -S ${DB_HOST_FQDN},${DB_PORT} -U "${USER_USERNAME}" -P "${USER_PASSWORD}" -C -l 60 -h -1 >/tmp/select_stdout.$$ 2>/tmp/select_stderr.$$
if [[ -s /tmp/select_stdout.$$ ]]; then echo "dtix ok $DB_SCHEMA schema $DB_HOST_FQDN,${DB_PORT} $DBA_USERNAME"; 
else cat /tmp/sqlcmd_stdout.$$ /tmp/sqlcmd_stderr.$$; return 1; fi
