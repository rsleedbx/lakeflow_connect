/** --------------------------------------------------------------------------------------------------------
  * T-SQL script that drops any pre-existing and/or creates DDL support objects required to capture DDL
  * changes happening on the database. Script offers four behaviors depending on the value set in the 'mode'
  * variable defined just bellow this description. 'mode' variable supports one of following values:
  * - CT -> initialize CT objects
  * - NONE -> delete all pre-existing CT and CDC objects
  * Script creates defined (if any) DDL support objects on the catalog level and in 'dbo' schema.
  *
  * Additionally, if 'replicationUser' variable is set, script grants privileges required to work with the
  * DDL support objects to the provided user.
  *
  * The _1_1 part in the new names is the version suffix. It is composed as _<major_version>_<minor_version>.
  * So the new objects are treated as major version = 1, and minor version = 1. Legacy objects are treated as
  * major version = 1, and minor version = 0.
  *
  * Gateway will work with both legacy and new names.
  * In general, major version will be upgraded only on backwards incompatible changes.
  * -------------------------------------------------------------------------------------------------------- */
BEGIN

    SET QUOTED_IDENTIFIER ON;

    DECLARE @mode NVARCHAR(10);
    SET @mode = 'BOTH'; -- ** SET THE MODE HERE ** ['CT'|'NONE']

    DECLARE @replicationUser NVARCHAR(100);
    SET @replicationUser = ''; -- ** SET THE USERNAME HERE **

    DECLARE @currentCatalogName VARCHAR(150);
    SET @currentCatalogName = DB_NAME();

    ------------------------------------
    -- Setup error codes and messages --
    ------------------------------------

    DECLARE @invalidModeErrorCode INT,
        @invalidModeErrorMessage VARCHAR(200),
        @cdcNotEnabledOnCatalogErrorCode INT,
        @cdcNotEnabledOnCatalogErrorMessage VARCHAR(200),
        @ctNotEnabledOnCatalogErrorCode INT,
        @ctNotEnabledOnCatalogErrorMessage VARCHAR(200),
        @createTriggerFailureErrorCode INT,
        @insufficientUserPrivilegesCode INT,
        @insufficientUserPrivilegesErrorMessage VARCHAR(200);

    SET @invalidModeErrorCode = 100000;
    SET @invalidModeErrorMessage = CONCAT('Provided execution mode: ', @mode, ', is not recognized. Allowed values are: BOTH, CT, CDC, NONE');
    SET @cdcNotEnabledOnCatalogErrorCode = 100100;
    SET @cdcNotEnabledOnCatalogErrorMessage = CONCAT('Change data capture is not enabled on catalog: ', @currentCatalogName, '. Please enable CDC on the catalog and re-run the script.');
    SET @ctNotEnabledOnCatalogErrorCode = 100200;
    SET @ctNotEnabledOnCatalogErrorMessage = CONCAT('Change tracking is not enabled on catalog: ', @currentCatalogName, '. Please enable CT on the catalog and re-run the script.');
    SET @createTriggerFailureErrorCode = 100300;
    SET @insufficientUserPrivilegesErrorMessage = 'User executing this script is not a ''db_owner'' role member. To execute this script, please use a user that is.';
    SET @insufficientUserPrivilegesCode = 100400;

    -- Generic error message variable to be used when throwing errors. It is expected that each piece of code will set this to appropriate value.
    DECLARE @genericErrorMessage NVARCHAR(4000);
    DECLARE @genericErrorState INT;
    DECLARE @genericErrorCode INT;

    ----------------------
    -- Setup validation --
    ----------------------

    -- Validate that current user is db_owner
    IF (IS_ROLEMEMBER ('db_owner') = 0)
        BEGIN;
            THROW @insufficientUserPrivilegesCode, @insufficientUserPrivilegesErrorMessage, 1;
        END;

    -- Validate execution mode has a valid value
    IF (@mode != 'BOTH' AND @mode != 'CT' AND @mode != 'CDC' AND @mode != 'NONE')
        BEGIN;
            THROW @invalidModeErrorCode, @invalidModeErrorMessage, 1;
        END;

    -- Validate if CT is enabled on catalog, if the mode expects it to be enabled
    IF (@mode = 'BOTH' OR @mode = 'CT')
        BEGIN;
            DECLARE @ctEnabled INT;

            SET @ctEnabled = (SELECT database_id FROM sys.change_tracking_databases WHERE database_id=DB_ID(@currentCatalogName));

            IF @ctEnabled IS NULL
                THROW @ctNotEnabledOnCatalogErrorCode, @ctNotEnabledOnCatalogErrorMessage, 1;
        END;

    ----------------------------------
    -- Drop legacy objects if exist --
    ----------------------------------

    -- Cleanup triggers
    BEGIN
        DECLARE @legacyAlterTableTriggerName VARCHAR(50),
                @legacyDDLAuditTriggerName VARCHAR(50);

        SET @legacyAlterTableTriggerName = 'alterTableTrigger_1';
        SET @legacyDDLAuditTriggerName = 'replicate_io_audit_ddl_trigger_1';

        IF EXISTS (SELECT name FROM sys.triggers WHERE [name] = @legacyAlterTableTriggerName AND [type] = 'TR')
            BEGIN;
                EXECUTE('DROP TRIGGER ' + @legacyAlterTableTriggerName + ' ON DATABASE');
            END;

        IF EXISTS (SELECT name FROM sys.triggers WHERE [name] = @legacyDDLAuditTriggerName AND [type] = 'TR')
            BEGIN;
                EXECUTE('DROP TRIGGER ' + @legacyDDLAuditTriggerName + ' ON DATABASE');
            END;
    END

    -- Cleanup procedures
    BEGIN
        DECLARE @legacyDisableOldCaptureInstanceProcedureName VARCHAR(50),
            @legacyRefreshCaptureInstanceProcedureName VARCHAR(50),
            @legacyMergeCaptureInstancesProcedureName VARCHAR(50);

        SET @legacyDisableOldCaptureInstanceProcedureName = 'dbo.disableOldCaptureInstance_1';
        SET @legacyRefreshCaptureInstanceProcedureName = 'dbo.refreshCaptureInstance_1';
        SET @legacyMergeCaptureInstancesProcedureName = 'dbo.mergeCaptureInstance_1';

        IF OBJECT_ID(@legacyDisableOldCaptureInstanceProcedureName, 'P') IS NOT NULL
            EXECUTE('DROP PROCEDURE ' + @legacyDisableOldCaptureInstanceProcedureName);

        IF OBJECT_ID(@legacyRefreshCaptureInstanceProcedureName, 'P') IS NOT NULL
            EXECUTE('DROP PROCEDURE ' + @legacyRefreshCaptureInstanceProcedureName);

        IF OBJECT_ID(@legacyMergeCaptureInstancesProcedureName, 'P') IS NOT NULL
            EXECUTE('DROP PROCEDURE ' + @legacyMergeCaptureInstancesProcedureName);
    END

    -- Cleanup tables
    BEGIN
        DECLARE @legacyDDLAuditTableName VARCHAR(50),
            @legacyCaptureInstanceTrackerTableName VARCHAR(50),
            @legacyAuditTableConstraintsDDLTableName VARCHAR(50),
            @legacyAuditSchemaDDLTableName VARCHAR(50);

        SET @legacyDDLAuditTableName = 'dbo.replicate_io_audit_ddl_1';
        SET @legacyCaptureInstanceTrackerTableName = 'dbo.captureInstanceTracker_1';
        SET @legacyAuditTableConstraintsDDLTableName = 'dbo.replicate_io_audit_tbl_cons_1';
        SET @legacyAuditSchemaDDLTableName = 'dbo.replicate_io_audit_tbl_schema_1';

        IF OBJECT_ID(@legacyDDLAuditTableName, 'U') IS NOT NULL
            EXECUTE('DROP TABLE ' + @legacyDDLAuditTableName);

        IF OBJECT_ID(@legacyCaptureInstanceTrackerTableName, 'U') IS NOT NULL
            EXECUTE('DROP TABLE ' + @legacyCaptureInstanceTrackerTableName);

        IF OBJECT_ID(@legacyAuditTableConstraintsDDLTableName, 'U') IS NOT NULL
            EXECUTE('DROP TABLE ' + @legacyAuditTableConstraintsDDLTableName);

        IF OBJECT_ID(@legacyAuditSchemaDDLTableName, 'U') IS NOT NULL
            EXECUTE('DROP TABLE ' + @legacyAuditSchemaDDLTableName);
    END

    ---------------------------
    -- Variable declarations --
    ---------------------------
    DECLARE @majorVersion INT;
    DECLARE @minorVersion INT;
    DECLARE @versionSuffix NVARCHAR(25);

    DECLARE @versionSuffixPattern NVARCHAR(25);

    DECLARE @captureInstanceTableNamePrefix NVARCHAR(255);
    DECLARE @captureInstanceTableName NVARCHAR(255);
    DECLARE @captureInstanceTableNamePattern NVARCHAR(255);

    DECLARE @ddlAuditTableNamePrefix NVARCHAR(255);
    DECLARE @ddlAuditTableName NVARCHAR(255);
    DECLARE @ddlAuditTableNamePattern NVARCHAR(255);

    DECLARE @disableOldCaptureInstanceProcedureNamePrefix NVARCHAR(255);
    DECLARE @disableOldCaptureInstanceProcedureName NVARCHAR(255);
    DECLARE @disableOldCaptureInstanceProcedureNamePattern NVARCHAR(255);

    DECLARE @mergeCaptureInstancesProcedureNamePrefix NVARCHAR(255);
    DECLARE @mergeCaptureInstancesProcedureName NVARCHAR(255);
    DECLARE @mergeCaptureInstancesProcedureNamePattern NVARCHAR(255);

    DECLARE @refreshCaptureInstanceProcedureNamePrefix NVARCHAR(255);
    DECLARE @refreshCaptureInstanceProcedureName NVARCHAR(255);
    DECLARE @refreshCaptureInstanceProcedureNamePattern NVARCHAR(255);

    DECLARE @alterTableTriggerNamePrefix NVARCHAR(255);
    DECLARE @alterTableTriggerName NVARCHAR(255);
    DECLARE @alterTableTriggerNamePattern NVARCHAR(255);

    DECLARE @ddlAuditTriggerNamePrefix NVARCHAR(255);
    DECLARE @ddlAuditTriggerName NVARCHAR(255);
    DECLARE @ddlAuditTriggerNamePattern NVARCHAR(255);

    ------------------------------
    -- Variable initializations --
    ------------------------------
    SET @majorVersion = 1;
    SET @minorVersion = 1;

    SET @versionSuffix = CONCAT('_', @majorVersion, '_', @minorVersion);
    SET @versionSuffixPattern = '[_]%[_]%';

    SET @captureInstanceTableNamePrefix = 'lakeflowCaptureInstanceInfo';
    SET @captureInstanceTableName = @captureInstanceTableNamePrefix + @versionSuffix;
    SET @captureInstanceTableNamePattern = @captureInstanceTableNamePrefix + @versionSuffixPattern;

    SET @ddlAuditTableNamePrefix = 'lakeflowDdlAudit';
    SET @ddlAuditTableName = @ddlAuditTableNamePrefix + @versionSuffix;
    SET @ddlAuditTableNamePattern = @ddlAuditTableNamePrefix + @versionSuffixPattern;

    SET @disableOldCaptureInstanceProcedureNamePrefix = 'lakeflowDisableOldCaptureInstance';
    SET @disableOldCaptureInstanceProcedureName = @disableOldCaptureInstanceProcedureNamePrefix + @versionSuffix;
    SET @disableOldCaptureInstanceProcedureNamePattern =
            @disableOldCaptureInstanceProcedureNamePrefix + @versionSuffixPattern;

    SET @mergeCaptureInstancesProcedureNamePrefix = 'lakeflowMergeCaptureInstances';
    SET @mergeCaptureInstancesProcedureName = @mergeCaptureInstancesProcedureNamePrefix + @versionSuffix;
    SET @mergeCaptureInstancesProcedureNamePattern = @mergeCaptureInstancesProcedureNamePrefix + @versionSuffixPattern;

    SET @refreshCaptureInstanceProcedureNamePrefix = 'lakeflowRefreshCaptureInstance';
    SET @refreshCaptureInstanceProcedureName = @refreshCaptureInstanceProcedureNamePrefix + @versionSuffix;
    SET @refreshCaptureInstanceProcedureNamePattern =
            @refreshCaptureInstanceProcedureNamePrefix + @versionSuffixPattern;

    SET @alterTableTriggerNamePrefix = 'lakeflowAlterTableTrigger';
    SET @alterTableTriggerName = @alterTableTriggerNamePrefix + @versionSuffix;
    SET @alterTableTriggerNamePattern = @alterTableTriggerNamePrefix + @versionSuffixPattern;

    SET @ddlAuditTriggerNamePrefix = 'lakeflowDdlAuditTrigger';
    SET @ddlAuditTriggerName = @ddlAuditTriggerNamePrefix + @versionSuffix;
    SET @ddlAuditTriggerNamePattern = @ddlAuditTriggerNamePrefix + @versionSuffixPattern;

    ----------------------------------------------------------------------
    -- Generic drop; Scans the catalog for existing DDL support objects --
    -- across versions and drops any object that is found.              --
    ----------------------------------------------------------------------
    -- Drop alter table trigger if exists across versions
    BEGIN TRY
        EXECUTE ('
            DECLARE @triggerName NVARCHAR(50);
            DECLARE trigger_cursor CURSOR FOR
                SELECT name
                FROM sys.triggers
                WHERE name LIKE ''' + @alterTableTriggerNamePattern + ''';

            OPEN trigger_cursor;
            FETCH NEXT FROM trigger_cursor INTO @triggerName;

            WHILE @@FETCH_STATUS = 0
            BEGIN;
                EXEC(''DROP TRIGGER '' + @triggerName + '' ON DATABASE'');
                FETCH NEXT FROM trigger_cursor INTO @triggerName;
            END;

            CLOSE trigger_cursor;
            DEALLOCATE trigger_cursor;
        ');
    END TRY
    BEGIN CATCH
        SET @genericErrorMessage = FORMATMESSAGE('Encountered error while dropping Alter table triggers; %s Internal error line: %d.', ERROR_MESSAGE(), ERROR_LINE());
        SET @genericErrorCode = 50000 + ERROR_NUMBER();
        SET @genericErrorState = ERROR_STATE();

        THROW @genericErrorCode, @genericErrorMessage, @genericErrorState;
    END CATCH

    -- Drop ddl audit trigger if exists across versions
    BEGIN TRY
        EXECUTE ('
            DECLARE @triggerName NVARCHAR(50);
            DECLARE trigger_cursor CURSOR FOR
                SELECT name
                FROM sys.triggers
                WHERE name LIKE ''' + @ddlAuditTriggerNamePattern + ''';

            OPEN trigger_cursor;
            FETCH NEXT FROM trigger_cursor INTO @triggerName;

            WHILE @@FETCH_STATUS = 0
            BEGIN;
                EXEC(''DROP TRIGGER '' + @triggerName + '' ON DATABASE'');
                FETCH NEXT FROM trigger_cursor INTO @triggerName;
            END;

            CLOSE trigger_cursor;
            DEALLOCATE trigger_cursor;
        ');
    END TRY
    BEGIN CATCH
        SET @genericErrorMessage = FORMATMESSAGE('Encountered error while dropping DDL audit triggers; %s Internal error line: %d.', ERROR_MESSAGE(), ERROR_LINE());
        SET @genericErrorCode = 50000 + ERROR_NUMBER();
        SET @genericErrorState = ERROR_STATE();

        THROW @genericErrorCode, @genericErrorMessage, @genericErrorState;
    END CATCH

    -- Drop capture instance table if exists across versions
    BEGIN TRY
        EXECUTE ('
            DECLARE @catalogName NVARCHAR(255);
            DECLARE @schemaName NVARCHAR(255);

            SELECT @catalogName = DB_NAME();
            SET @schemaName = ''dbo'';

            DECLARE @dropTableSql varchar(4000);
            DECLARE tableName CURSOR FOR
                SELECT ''DROP TABLE ['' + Table_Name + '']''
                FROM INFORMATION_SCHEMA.TABLES
                WHERE Table_Name LIKE ''' + @captureInstanceTableNamePattern + ''';

            OPEN tableName;
            WHILE 1 = 1
            BEGIN;
                FETCH tableName INTO @dropTableSql;
                IF @@fetch_status != 0 BREAK
                    EXEC(@dropTableSql);
            END;
            CLOSE tableName;
            DEALLOCATE tableName;
        ');
    END TRY
    BEGIN CATCH
        SET @genericErrorMessage = FORMATMESSAGE('Encountered error while dropping Capture instance tracker tables; %s Internal error line: %d.', ERROR_MESSAGE(), ERROR_LINE());
        SET @genericErrorCode = 50000 + ERROR_NUMBER();
        SET @genericErrorState = ERROR_STATE();

        THROW @genericErrorCode, @genericErrorMessage, @genericErrorState;
    END CATCH

    -- Drop ddl audit table if exists across versions
    BEGIN TRY
        EXECUTE ('
            DECLARE @tableName varchar(4000);
            DECLARE tableNameCursor CURSOR FOR
                SELECT name
                FROM sys.objects
                WHERE schema_id = SCHEMA_ID(''dbo'') AND name LIKE ''' + @ddlAuditTableNamePattern + ''';

            OPEN tableNameCursor;
            WHILE 1 = 1
            BEGIN;
                FETCH tableNameCursor INTO @tableName;
                IF @@fetch_status != 0 BREAK
                    EXEC(''DROP TABLE [dbo].['' + @tableName + '']'');
            END;
            CLOSE tableNameCursor;
            DEALLOCATE tableNameCursor;
        ');
    END TRY
    BEGIN CATCH
        SET @genericErrorMessage = FORMATMESSAGE('Encountered error while dropping DDL audit tables; %s Internal error line: %d.', ERROR_MESSAGE(), ERROR_LINE());
        SET @genericErrorCode = 50000 + ERROR_NUMBER();
        SET @genericErrorState = ERROR_STATE();

        THROW @genericErrorCode, @genericErrorMessage, @genericErrorState;
    END CATCH

    -- Drop disable old capture instance procedure if exists across versions
    BEGIN TRY
        EXECUTE ('
            DECLARE @DropScript varchar(max)
            SET @DropScript = ''''

            SELECT @DropScript = @DropScript + ''DROP PROCEDURE ['' + schema_name(schema_id)+ ''].'' + ''['' + name + '']''
            FROM sys.procedures
            WHERE NAME LIKE ''' + @disableOldCaptureInstanceProcedureNamePattern + '''

            EXEC (@DropScript)
        ');
    END TRY
    BEGIN CATCH
        SET @genericErrorMessage = FORMATMESSAGE('Encountered error while dropping Disable old capture instance procedures; %s Internal error line: %d.', ERROR_MESSAGE(), ERROR_LINE());
        SET @genericErrorCode = 50000 + ERROR_NUMBER();
        SET @genericErrorState = ERROR_STATE();

        THROW @genericErrorCode, @genericErrorMessage, @genericErrorState;
    END CATCH

    -- Drop merge capture instances procedure if exists across versions
    BEGIN TRY
        EXECUTE ('
            DECLARE @DropScript varchar(max)
            SET @DropScript = ''''

            SELECT @DropScript = @DropScript + ''DROP PROCEDURE ['' + schema_name(schema_id)+ ''].'' + ''['' + name + '']''
            FROM sys.procedures
            WHERE NAME LIKE ''' + @mergeCaptureInstancesProcedureNamePattern + '''

            EXEC (@DropScript)
        ');
    END TRY
    BEGIN CATCH
        SET @genericErrorMessage = FORMATMESSAGE('Encountered error while dropping Merge capture instances procedures; %s Internal error line: %d.', ERROR_MESSAGE(), ERROR_LINE());
        SET @genericErrorCode = 50000 + ERROR_NUMBER();
        SET @genericErrorState = ERROR_STATE();

        THROW @genericErrorCode, @genericErrorMessage, @genericErrorState;
    END CATCH

    -- Drop refresh capture instance procedure if exists across versions
    BEGIN TRY
        EXECUTE ('
            DECLARE @DropScript varchar(max)
            SET @DropScript = ''''

            SELECT @DropScript = @DropScript + ''DROP PROCEDURE ['' + schema_name(schema_id)+ ''].'' + ''['' + name + '']''
            FROM sys.procedures
            WHERE NAME LIKE ''' + @refreshCaptureInstanceProcedureNamePattern + '''

            EXEC (@DropScript)
        ');
    END TRY
    BEGIN CATCH
        SET @genericErrorMessage = FORMATMESSAGE('Encountered error while dropping Refresh capture instance procedures; %s Internal error line: %d.', ERROR_MESSAGE(), ERROR_LINE());
        SET @genericErrorCode = 50000 + ERROR_NUMBER();
        SET @genericErrorState = ERROR_STATE();

        THROW @genericErrorCode, @genericErrorMessage, @genericErrorState;
    END CATCH

    --------------------------------
    -- Create DDL support objects --
    --------------------------------
    IF (@mode = 'NONE')
    BEGIN;
        RETURN
    END;

    IF (@mode = 'BOTH' OR @mode = 'CT')
        -- Create CT DDL support objects
        BEGIN;
            -- Create DDL audit table
            BEGIN TRY
                EXECUTE ('
                    CREATE TABLE [dbo].[' + @ddlAuditTableName + '](
                        [SERIAL_NUMBER] INT IDENTITY NOT NULL,
                        [CURRENT_USER] NVARCHAR(128) NULL,
                        [SCHEMA_NAME] NVARCHAR(128) NULL,
                        [TABLE_NAME] NVARCHAR(128) NULL,
                        [TYPE] NVARCHAR(30) NULL,
                        [OPERATION_TYPE] NVARCHAR(30) NULL,
                        [SQL_TXT] NVARCHAR(2000) NULL,
                        [LOGICAL_POSITION] BIGINT NOT NULL,
                        CONSTRAINT [replicantDdlAuditPrimaryKey] PRIMARY KEY ([SERIAL_NUMBER], [LOGICAL_POSITION]))');
            END TRY
            BEGIN CATCH
                SET @genericErrorMessage = FORMATMESSAGE('Encountered error while creating DDL audit table; %s Internal error line: %d.', ERROR_MESSAGE(), ERROR_LINE());
                SET @genericErrorCode = 50000 + ERROR_NUMBER();
                SET @genericErrorState = ERROR_STATE();

                THROW @genericErrorCode, @genericErrorMessage, @genericErrorState;
            END CATCH

            -- Enable Change tracking on DDL audit table
            BEGIN TRY
                EXECUTE ('ALTER TABLE dbo.' + @ddlAuditTableName + ' ENABLE CHANGE_TRACKING');
            END TRY
            BEGIN CATCH
                SET @genericErrorMessage = FORMATMESSAGE('Encountered error while enabling Change tracking on DDL audit table; %s Internal error line: %d.', ERROR_MESSAGE(), ERROR_LINE());
                SET @genericErrorCode = 50000 + ERROR_NUMBER();
                SET @genericErrorState = ERROR_STATE();

                THROW @genericErrorCode, @genericErrorMessage, @genericErrorState;
            END CATCH

            -- Create DDL audit trigger
            BEGIN TRY
                EXECUTE('
                    CREATE TRIGGER ' + @ddlAuditTriggerName + '
                    ON DATABASE
                    AFTER ALTER_TABLE
                    AS
                        SET NOCOUNT ON;

                        DECLARE @DbName NVARCHAR(255),
                                @SchemaName NVARCHAR(max),
                                @TableName NVARCHAR(255),
                                @objectType NVARCHAR(30),
                                @data XML,
                                @changeVersion NVARCHAR(30),
                                @operation NVARCHAR(30),
                                @capturedSql NVARCHAR(2000),
                                @isCTEnabledDBLevel bit,
                                @isCTEnabledTableLevel bit,
                                @isColumnAdd nvarchar(255),
                                @isAlterColumn nvarchar(255),
                                @isDropColumn nvarchar(255);

                        SET @data = EVENTDATA();
                        SET @changeVersion = CHANGE_TRACKING_CURRENT_VERSION();
                        SET @DbName = DB_NAME();
                        SET @SchemaName = @data.value(''(/EVENT_INSTANCE/SchemaName)[1]'',  ''NVARCHAR(MAX)'');
                        SET @TableName = @data.value(''(/EVENT_INSTANCE/ObjectName)[1]'',  ''NVARCHAR(255)'');
                        SET @objectType = @data.value(''(/EVENT_INSTANCE/ObjectType)[1]'', ''NVARCHAR(30)'');
                        SET @operation = @data.value(''(/EVENT_INSTANCE/EventType)[1]'', ''NVARCHAR(30)'');
                        SET @capturedSql = @data.value(''(/EVENT_INSTANCE/TSQLCommand/CommandText)[1]'', ''NVARCHAR(2000)'');
                        SET @isCTEnabledDBLevel = (SELECT COUNT(*) FROM sys.change_tracking_databases WHERE database_id=DB_ID(@DbName));
                        SET @isCTEnabledTableLevel = (SELECT COUNT(*) FROM sys.change_tracking_tables WHERE object_id = object_id(''['' + @SchemaName + ''].['' + @TableName + '']''));
                        SET @isColumnAdd = @data.value(''(/EVENT_INSTANCE/AlterTableActionList/Create)[1]'', ''NVARCHAR(255)'');
                        SET @isAlterColumn = @data.value(''(/EVENT_INSTANCE/AlterTableActionList/Alter)[1]'', ''NVARCHAR(255)'');
                        SET @isDropColumn = @data.value(''(/EVENT_INSTANCE/AlterTableActionList/Drop)[1]'', ''NVARCHAR(255)'');
                    IF ((@isCTEnabledDBLevel = 1 AND @isCTEnabledTableLevel = 1) AND ((@isColumnAdd IS NOT NULL) OR (@isAlterColumn IS NOT NULL) OR (@isDropColumn IS NOT NULL)))
                    BEGIN
                        DECLARE @insertSql nvarchar(1000);
                        SET @insertSql = N''INSERT INTO ['' + @DbName + ''].dbo.' + @ddlAuditTableName + '(
                                                [CURRENT_USER], [SCHEMA_NAME], [TABLE_NAME], [TYPE], [OPERATION_TYPE], [SQL_TXT], [LOGICAL_POSITION])
                                            VALUES(
                                                '''''' + SUSER_NAME() + '''''',
                                                '''''' + @SchemaName + '''''',
                                                '''''' + @TableName + '''''',
                                                '''''' + @objectType + '''''',
                                                '''''' + @operation + '''''',
                                                '''''' + @capturedSql + '''''',
                                                '' + @changeVersion + '');'';

                        EXECUTE (@insertSql);
                    END
                ');
            END TRY
            BEGIN CATCH
                SET @genericErrorMessage = FORMATMESSAGE('Encountered error while creating DDL audit trigger; %s Internal error line: %d. Trigger name: %s', ERROR_MESSAGE(), ERROR_LINE(), ERROR_PROCEDURE());
                SET @genericErrorCode = 50000 + ERROR_NUMBER();
                SET @genericErrorState = ERROR_STATE();

                THROW @genericErrorCode, @genericErrorMessage, @genericErrorState;
            END CATCH

            IF (@replicationUser > '')
            BEGIN
                EXECUTE ('
                    GRANT SELECT ON OBJECT::dbo.' + @ddlAuditTableName + ' TO [' + @replicationUser + '];
                    GRANT VIEW CHANGE TRACKING ON OBJECT::dbo.' + @ddlAuditTableName + ' TO [' + @replicationUser + '];
                    GRANT VIEW DEFINITION TO [' + @replicationUser + '];
                ');
            END
        END;
END