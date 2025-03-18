-- $DB_CATALOG
if exists (select * from sys.change_tracking_databases where database_id=db_id())
    BEGIN
        select 'CT already enabled'
    END
else
    BEGIN
        select 'enable ct on database';
        exec ('ALTER DATABASE $DB_CATALOG SET CHANGE_TRACKING = ON (CHANGE_RETENTION = 3 DAYS, AUTO_CLEANUP = ON)');
    END 
go
if exists (select name, is_cdc_enabled from sys.databases where name=db_name() and is_cdc_enabled=1)
    BEGIN
        select 'CDC already enabled'
    END
ELSE
    BEGIN
        if exists(SELECT name, schema_name(schema_id) FROM sys.objects WHERE type = 'P' and name='sp_cdc_enable_db')
            BEGIN
                select 'enable cdc on database sys.sp_cdc_enable_db';
                EXEC sys.sp_cdc_enable_db
            END
        else if exists(SELECT name, schema_name(schema_id) FROM msdb.sys.objects WHERE type = 'P' and name='gcloudsql_cdc_enable_db')
            BEGIN
                select 'enable cdc on database msdb.dbo.gcloudsql_cdc_enable_db';
                EXEC msdb.dbo.gcloudsql_cdc_enable_db $DB_CATALOG;
            END
        else if exists(SELECT name, schema_name(schema_id) FROM msdb.sys.objects WHERE type = 'P' and name='rds_cdc_enable_db')
            BEGIN
                select 'enable cdc on database msdb.dbo.rds_cdc_enable_db';
                EXEC msdb.dbo.rds_cdc_enable_db '$DB_CATALOG' 
            END
        else
            BEGIN
                select 'cdc enable stored proc does not exist'
            END
    END
go