#!/usr/bin/env bash

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
    if [[ -f ./create_azure_sqlserver_01.sh ]]; then
        source ./create_azure_sqlserver_01.sh
    else
        source <(curl -s -L https://raw.githubusercontent.com/rsleedbx/lakeflow_connect/refs/heads/sqlserver/sqlserver/create_azure_sqlserver_01.sh)
    fi
fi

# #############################################################################

# connect to master catalog
echo "select 1" | sqlcmd -S $DB_HOST_FQDN,${DB_PORT} -U $DBA_USERNAME -P $DBA_PASSWORD 

# connect to $DB_CATALOG
echo "select 1" | sqlcmd -S $DB_HOST_FQDN,${DB_PORT} -U $DBA_USERNAME -P $DBA_PASSWORD -d $DB_CATALOG

# #############################################################################

cat <<EOF | sqlcmd -S ${DB_HOST_FQDN},${DB_PORT} -U "${DBA_USERNAME}" -P "${DBA_PASSWORD}" -C -l 60 -e
-- alter is not supported in Azure SQL MI
alter database ${DB_CATALOG} set online
go
EOF

# #############################################################################

cat <<EOF | sqlcmd -S ${DB_HOST_FQDN},${DB_PORT} -U "${DBA_USERNAME}" -P "${DBA_PASSWORD}" -C -l 60 -e
CREATE LOGIN ${USER_USERNAME} WITH PASSWORD = '${USER_PASSWORD}'
go
alter login ${USER_USERNAME} with password = '${USER_PASSWORD}'
go
-- gcp does not allow user login
CREATE USER ${USER_USERNAME} FOR LOGIN ${USER_USERNAME} WITH DEFAULT_SCHEMA=dbo
go
EOF

# connect to master
echo "select 1" | sqlcmd -S $DB_HOST_FQDN,${DB_PORT} -U $USER_USERNAME -P $USER_PASSWORD

# #############################################################################

cat <<EOF | sqlcmd -d ${DB_CATALOG} -S ${DB_HOST_FQDN},${DB_PORT} -U "${DBA_USERNAME}" -P "${DBA_PASSWORD}" -C -l 60 -e
CREATE USER ${USER_USERNAME} FOR LOGIN ${USER_USERNAME} WITH DEFAULT_SCHEMA=dbo
go
ALTER ROLE db_owner ADD MEMBER ${USER_USERNAME}
go
ALTER ROLE db_ddladmin ADD MEMBER ${USER_USERNAME}
go
EOF

# connect to $DB_CATALOG
echo "select 1" | sqlcmd -d ${DB_CATALOG} -S $DB_HOST_FQDN,${DB_PORT} -U $USER_USERNAME -P $USER_PASSWORD -d $DB_CATALOG

# #############################################################################

cat <<EOF | sqlcmd -d ${DB_CATALOG} -S ${DB_HOST_FQDN},${DB_PORT} -U "${DBA_USERNAME}" -P "${DBA_PASSWORD}" -C -l 60 -e
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

# #############################################################################

cat <<EOF | sqlcmd -d ${DB_CATALOG} -S ${DB_HOST_FQDN},${DB_PORT} -U "${DBA_USERNAME}" -P "${DBA_PASSWORD}" -C -l 60 -e
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

# #############################################################################

wget -qO- https://raw.githubusercontent.com/rsleedbx/lakeflow_connect/refs/heads/main/sqlserver/ddl_support_objects.sql | \
  sed "s/SET \@replicationUser = '';/SET \@replicationUser = '${USER_USERNAME}';/" | \
  sqlcmd -d "${DB_CATALOG}" -S ${DB_HOST_FQDN},${DB_PORT} -U "${DBA_USERNAME}" -P "${DBA_PASSWORD}" -C -l 60 

# #############################################################################

cat <<EOF | sqlcmd -d ${DB_CATALOG} -S ${DB_HOST_FQDN},${DB_PORT} -U "${USER_USERNAME}" -P "${USER_PASSWORD}" -C -l 60 -e
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

# #############################################################################

cat <<EOF | sqlcmd -d ${DB_CATALOG} -S ${DB_HOST_FQDN},${DB_PORT} -U "${USER_USERNAME}" -P "${USER_PASSWORD}" -C -l 60 -e
insert into [${DB_SCHEMA}].[intpk] (dt) values (CURRENT_TIMESTAMP),(CURRENT_TIMESTAMP), (CURRENT_TIMESTAMP)
go
insert into [${DB_SCHEMA}].[dtix] (dt) values (CURRENT_TIMESTAMP),(CURRENT_TIMESTAMP),(CURRENT_TIMESTAMP)
go
delete from [${DB_SCHEMA}].[intpk] where pk=(select min(pk) from [${DB_SCHEMA}].[intpk])
go
update [${DB_SCHEMA}].[intpk] set dt=CURRENT_TIMESTAMP where pk=(select min(pk) from [${DB_SCHEMA}].[intpk])
go
EOF
