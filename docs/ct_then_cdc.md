# enable just CT
export CDC_CT_MODE=CT
export PIPELINE_DEV_MODE=true
export DATABRICKS_CONFIG_PROFILE=e2demofe

. ./00_lakeflow_connect_env.sh
. ./sqlserver/01_azure_sqlserver.sh
. ./sqlserver/02_sqlserver_configure.sh
. ./03_lakeflow_connect_demo.sh 

# enable BOTH good path
export CDC_CT_MODE=BOTH
set_repl_on_table   # in case of removal
set_cdc_on_catalog
set_sch_evo
set_repl_on_table   # in case of setting 

DB_EXIT_ON_ERROR="PRINT_RETURN" DBX pipelines stop $GATEWAY_PIPELINE_ID
sleep 20; DB_EXIT_ON_ERROR="PRINT_RETURN" DBX pipelines start-update $GATEWAY_PIPELINE_ID

DB_EXIT_ON_ERROR="PRINT_RETURN" DBX pipelines update $INGESTION_PIPELINE_ID --json "$ig_tables_spec"
DB_EXIT_ON_ERROR="PRINT_RETURN" DBX api delete /api/2.1/unity-catalog/tables/$TARGET_CATALOG.$TARGET_SCHEMA.dtix
DB_EXIT_ON_ERROR="PRINT_RETURN" DBX pipelines start-update $INGESTION_PIPELINE_ID

# however, if ingestion was updated first.  then we get into a bad state

DB_EXIT_ON_ERROR="PRINT_RETURN" DBX pipelines update $INGESTION_PIPELINE_ID --json "$ig_tables_spec"
DB_EXIT_ON_ERROR="PRINT_RETURN" DBX api delete /api/2.1/unity-catalog/tables/$TARGET_CATALOG.$TARGET_SCHEMA.dtix
DB_EXIT_ON_ERROR="PRINT_RETURN" DBX pipelines start-update $INGESTION_PIPELINE_ID

export CDC_CT_MODE=BOTH
set_repl_on_table   # in case of removal
set_cdc_on_catalog
set_sch_evo
set_repl_on_table   # in case of setting 

DB_EXIT_ON_ERROR="PRINT_RETURN" DBX pipelines stop $GATEWAY_PIPELINE_ID
sleep 20; DB_EXIT_ON_ERROR="PRINT_RETURN" DBX pipelines start-update $GATEWAY_PIPELINE_ID

DB_EXIT_ON_ERROR="PRINT_RETURN" DBX pipelines update $INGESTION_PIPELINE_ID --json "$ig_tables_spec"
DB_EXIT_ON_ERROR="PRINT_RETURN" DBX api delete /api/2.1/unity-catalog/tables/$TARGET_CATALOG.$TARGET_SCHEMA.dtix
DB_EXIT_ON_ERROR="PRINT_RETURN" DBX pipelines start-update $INGESTION_PIPELINE_ID



expect the gateway to error out 

DBX pipelines update $INGESTION_PIPELINE_ID --json "$ig_tables_spec"
cat /tmp/dbx_stderr.$$
GATEWAY detects cdc on catalog not enabled and cdc on table not enabled but does not report schema evolution status
enable cdc on catalog and table
DBX pipelines update $INGESTION_PIPELINE_ID --json "$ig_tables_spec"
gateway needs restart?

do a full refresh on the table (not a refresh)

ingestion in bad state and can't start

export CDC_CT_MODE=BOTH
export PIPELINE_DEV_MODE=true

intpk success

enable dtix via UI
  validataion, stop, validation again very slow

Update 30eedd has failed. Failed to analyze flow 'main_robertlee_6900c28a_dtix_cdc_flow' and 1 other flow(s)..
CDC is not enabled on table 'eem9thah.robertlee_lfcddemo.dtix'. Enable CDC and perform a full table refresh on the Ingestion Pipeline. Error message: ' Reason: - Table eem9thah.robertlee_lfcdde… Show more

enable CDC on table but not on DDL

# remove dtix from schema evolution

export CDC_CT_MODE=CT
set_repl_on_table   # unset replication on table
set_cdc_on_catalog
set_sch_evo
set_repl_on_table   # set replication on table

DB_EXIT_ON_ERROR="PRINT_RETURN" DBX pipelines stop $GATEWAY_PIPELINE_ID
sleep 10; DB_EXIT_ON_ERROR="PRINT_RETURN" DBX pipelines start-update $GATEWAY_PIPELINE_ID

DB_EXIT_ON_ERROR="PRINT_RETURN" DBX pipelines update $INGESTION_PIPELINE_ID --json "$ig_intpk_spec"
DB_EXIT_ON_ERROR="PRINT_RETURN" DBX api delete /api/2.1/unity-catalog/tables/$TARGET_CATALOG.$TARGET_SCHEMA.dtix
DB_EXIT_ON_ERROR="PRINT_RETURN" DBX pipelines start-update $INGESTION_PIPELINE_ID

# enable dtix 

export CDC_CT_MODE=BOTH
set_repl_on_table   # in case of removal
set_cdc_on_catalog
set_sch_evo
set_repl_on_table   # in case of setting 

DB_EXIT_ON_ERROR="PRINT_RETURN" DBX pipelines stop $GATEWAY_PIPELINE_ID
sleep 10; DB_EXIT_ON_ERROR="PRINT_RETURN" DBX pipelines start-update $GATEWAY_PIPELINE_ID

DB_EXIT_ON_ERROR="PRINT_RETURN" DBX pipelines update $INGESTION_PIPELINE_ID --json "$ig_tables_spec"
DB_EXIT_ON_ERROR="PRINT_RETURN" DBX api delete /api/2.1/unity-catalog/tables/$TARGET_CATALOG.$TARGET_SCHEMA.dtix
DB_EXIT_ON_ERROR="PRINT_RETURN" DBX pipelines start-update $INGESTION_PIPELINE_ID


1> .name TABLE_SCHEM, t.name as TABLE_NAME from sys.tables t left join sys.schemas s on t.schema_id = s.schema_id where t.is_tracked_by_cdc=1
2> go
TABLE_CAT                                                                                                                        TABLE_SCHEM                                                                                                                      TABLE_NAME                                                                                                                      
-------------------------------------------------------------------------------------------------------------------------------- -------------------------------------------------------------------------------------------------------------------------------- --------------------------------------------------------------------------------------------------------------------------------
eem9thah                                                                                                                         robertlee_lfcddemo                                                                                                               dtix                                                                                                                            


still report CDC is not enabled

enable CDC on table AND on DDL

perform full refresh via UI on just dtix

java.lang.IllegalArgumentException: Table dtix is not present in the graph to execute. Please check if there are any analysis failures for this table in the event log and if so, please remove the table from the full refresh list or fix the analysis failure.

YAML updated, but vi UI, but can't seem to get going

resources:
  pipelines:
    pipeline_robertlee_6900c28a_ig:
      name: robertlee_6900c28a_IG
      ingestion_definition:
        ingestion_gateway_id: 2145db31-df83-4ca3-9225-b3a7c4b32f51
        objects:
          - table:
              source_catalog: eem9thah
              source_schema: robertlee_lfcddemo
              source_table: intpk
              destination_catalog: main
              destination_schema: robertlee_6900c28a
          - table:
              source_catalog: eem9thah
              source_schema: robertlee_lfcddemo
              source_table: dtix
              destination_catalog: main
              destination_schema: robertlee_6900c28a
        source_type: SQLSERVER
      target: robertlee_6900c28a
      catalog: main

once enabled on the ingestion, gateway reports the following

ech.replicant.error.ReplicationException: CDC is not enabled on table 'eem9thah.robertlee_lfcddemo.dtix'. Enable CDC and perform a full table refresh on the Ingestion Pipeline. Error message: '

  Reason:
    - Table eem9thah.robertlee_lfcddemo.dtix is not correctly set up as neither CT nor CDC is enabled for it.




BUGS
Even if CLI sets development=True, UI updates resets to development=False

reported from UI after crated in CLI

resources:
  pipelines:
    pipeline_robertlee_6900d9fc_ig:
      name: robertlee_6900d9fc_IG
      ingestion_definition:
        ingestion_gateway_id: 625a7143-c5f5-454b-a5a3-0e56c7ca82c3
        objects:
          - table:
              source_catalog: eem9thah
              source_schema: robertlee_lfcddemo
              source_table: intpk
              destination_catalog: main
              destination_schema: robertlee_6900d9fc
        source_type: SQLSERVER
      target: robertlee_6900d9fc
      development: true
      catalog: main


gateway
DTIX is not a part of the replication tables but still reported as 
{"eventType":"CDC_NOT_ENABLED","message":"Flow 'gateway_cdc_dtix' has failed because of a fatal error during realtime phase","snapshot_request_timestamp":1761662414424}

CDC status of the catalog is not rediscovered



if CDC is not enabled the first time, rerunning does not seem to enable it

EXEC sp_tables @table_owner = N'dbo';

dbo.MSchange_tracking_history;