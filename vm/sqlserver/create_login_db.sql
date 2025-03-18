CREATE LOGIN ${DB_ARC_USER} WITH PASSWORD = '${MSSQL_SA_PASSWORD}'
go
alter login ${DB_ARC_USER} with password = '${MSSQL_SA_PASSWORD}'
go
CREATE USER ${DB_ARC_USER} FOR LOGIN ${DB_ARC_USER} WITH DEFAULT_SCHEMA=dbo
go
create database ${DB_DB}
go
alter database ${DB_DB} set online
go