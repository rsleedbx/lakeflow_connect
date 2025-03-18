create schema [${DB_SCHEMA}]
go
create table [${DB_SCHEMA}].[intpk] (pk int primary key)
go
insert into [${DB_SCHEMA}].[intpk] values (1),(2),(3)
go
ALTER TABLE [${DB_SCHEMA}].[intpk] ENABLE CHANGE_TRACKING WITH (TRACK_COLUMNS_UPDATED = ON) 
go
create table [${DB_SCHEMA}].[intix] (pk int)
go
insert into [${DB_SCHEMA}].[intix] values (1),(2),(3)
go
EXEC sys.sp_cdc_enable_table @source_schema = N'${DB_SCHEMA}', @source_name = N'intix', @role_name = NULL, @supports_net_changes = 0
go