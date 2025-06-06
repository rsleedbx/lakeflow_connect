ALTER DATABASE  ${DB_DB} SET CHANGE_TRACKING = ON (CHANGE_RETENTION = 2 DAYS, AUTO_CLEANUP = ON)  
go
EXECUTE sys.sp_cdc_enable_db
go
CREATE USER ${DB_ARC_USER} FOR LOGIN ${DB_ARC_USER} WITH DEFAULT_SCHEMA=dbo
go
ALTER ROLE db_owner ADD MEMBER ${DB_ARC_USER}
go
ALTER ROLE db_ddladmin ADD MEMBER ${DB_ARC_USER}
go
ALTER LOGIN ${DB_ARC_USER} WITH DEFAULT_DATABASE=[${DB_DB}]
go