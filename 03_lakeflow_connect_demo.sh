#!/usr/bin/env bash

# error out when undeclared variable is used
set -u 

# must be sourced for exports to continue to the next script
if [ "$0" == "$BASH_SOURCE" ]; then
  echo "Script is being executed directly. Please run as source $0"
  exit 1
fi

# stop the resource after this 1s 1m 1h ...
export STOP_AFTER_SLEEP=${STOP_AFTER_SLEEP:-"20m"}
# uncomment if delete is also desired.  
# Tag will also be created to ensure delete happens via automation in the cloud
# export DELETE_PIPELINES_AFTER_SLEEP=${DELETE_PIPELINES_AFTER_SLEEP:-"120m"}
# make unique schema, pipelines, job
NINE_CHAR_ID=$(date +%s | xargs printf "%08x\n") # number of seconds since epoch in hex
export NINE_CHAR_ID
# databricks URL (auth env is deprecated — use describe; login only if needed)
if ! DB_EXIT_ON_ERROR="" DBX auth describe; then
  echo "Databricks auth for profile '${DATABRICKS_CONFIG_PROFILE}' is not usable; running auth login..."
  # Interactive OAuth — call CLI directly (do not use DBX; it forces --output json)
  databricks auth login --profile "${DATABRICKS_CONFIG_PROFILE}" || { echo "ERROR: auth login failed" >&2; kill -INT $$; }
  DB_EXIT_ON_ERROR="PRINT_EXIT" DBX auth describe
fi
DATABRICKS_HOST_NAME="$(jq -r '.details.host // empty' /tmp/dbx_stdout.$$)"
DATABRICKS_HOST_NAME="${DATABRICKS_HOST_NAME%/}"
if [[ -z "$DATABRICKS_HOST_NAME" || "$DATABRICKS_HOST_NAME" == "null" ]]; then
  echo "ERROR: could not resolve Databricks host from auth describe" >&2
  kill -INT $$
fi
export DATABRICKS_HOST_NAME
# used for connection
if [[ -z "$CONNECTION_NAME" ]]; then 
    CONNECTION_NAME=$(echo "${WHOAMI}_${DB_HOST}_${DB_CATALOG}_${USER_USERNAME}" | tr [.@] _)
fi
export CONNECTION_NAME
# long name
#export GATEWAY_PIPELINE_NAME=${WHOAMI}_${NINE_CHAR_ID}_${GATEWAY_MIN_WORKERS}${GATEWAY_MAX_WORKERS}GMX_${GATEWAY_DRIVER_NODE:+${GATEWAY_DRIVER_NODE}GDN_}${GATEWAY_WORKER_NODE:+${GATEWAY_WORKER_NODE}GWN_}${INGESTION_PIPELINE_MIN_TRIGGER}TRG_${JOBS_PERFORMANCE_MODE:0:4}JPM_${PIPELINE_DEV_MODE:0:4}PDM_${DML_INTERVAL_SEC}TPS_${INITIAL_SNAPSHOT_ROWS}ROW_GW
#export INGESTION_PIPELINE_NAME=${WHOAMI}_${NINE_CHAR_ID}_${GATEWAY_MIN_WORKERS}${GATEWAY_MAX_WORKERS}GMX_${GATEWAY_DRIVER_NODE:+${GATEWAY_DRIVER_NODE}GDN_}${GATEWAY_WORKER_NODE:+${GATEWAY_WORKER_NODE}GWN_}${INGESTION_PIPELINE_MIN_TRIGGER}TRG_${JOBS_PERFORMANCE_MODE:0:4}JPM_${PIPELINE_DEV_MODE:0:4}PDM_${DML_INTERVAL_SEC}TPS_${INITIAL_SNAPSHOT_ROWS}ROW_IG
# short name with pipeline type + compute: e.g. ..._cdc_default_GW / ..._qbc_srvless_IG
case "${CDC_QBC}" in
    "cdc") PIPELINE_TYPE_TAG="cdc" ;;
    "qbc") PIPELINE_TYPE_TAG="qbc" ;;
    "cdc_single_pipeline"|"icdc") PIPELINE_TYPE_TAG="icdc" ;;
    *)
        echo "CDC_QBC=${CDC_QBC} must be cdc|qbc|cdc_single_pipeline" >&2
        kill -INT $$
    ;;
esac
case "${COMPUTE_GATEWAY}" in
    "classic") GATEWAY_COMPUTE_TAG="classic" ;;
    "serverless") GATEWAY_COMPUTE_TAG="srvless" ;;
    *) GATEWAY_COMPUTE_TAG="default" ;;
esac
case "${COMPUTE_INGEST}" in
    "classic") INGEST_COMPUTE_TAG="classic" ;;
    "serverless") INGEST_COMPUTE_TAG="srvless" ;;
    *) INGEST_COMPUTE_TAG="default" ;;
esac
export GATEWAY_PIPELINE_NAME=${WHOAMI}_${NINE_CHAR_ID}_${SOURCE_TYPE}_${PIPELINE_TYPE_TAG}_${GATEWAY_COMPUTE_TAG}_GW
export INGESTION_PIPELINE_NAME=${WHOAMI}_${NINE_CHAR_ID}_${SOURCE_TYPE}_${PIPELINE_TYPE_TAG}_${INGEST_COMPUTE_TAG}_IG
export CLEANUP_JOB_NAME=${WHOAMI}_${NINE_CHAR_ID}_cleanup
# used for the pipelines — default catalog from workspace settings when unset
if [[ -z "${TARGET_CATALOG:-}" ]]; then
    TARGET_CATALOG="$(resolve_default_uc_catalog)"
fi
export TARGET_CATALOG
export TARGET_SCHEMA=${WHOAMI}_${NINE_CHAR_ID}
export STAGING_CATALOG=${TARGET_CATALOG}
export STAGING_SCHEMA=${TARGET_SCHEMA}
if [[ -z "${ELOG_CATALOG:-}" ]]; then
    ELOG_CATALOG="${TARGET_CATALOG}"
fi
export ELOG_CATALOG
export ELOG_SCHEMA=${ELOG_SCHEMA:-${WHOAMI}}
# check access to SQL Server

function cleanup() {
    if [[ -n "${DELETE_DB_AFTER_SLEEP}" ]]; then
        CLEANUP nohup sleep "${DELETE_DB_AFTER_SLEEP}" && DBX connections delete "$CONNECTION_NAME" >> ~/nohup.out 2>&1 &
        CLEANUP echo -e "\nDeleting connection ${CONNECTION_NAME} after ${DELETE_DB_AFTER_SLEEP}.  To cancel kill -9 $! \n" 
    fi
}

# #############################################################################

echo -e "\nCreate target and staging schemas"
echo -e   "---------------------------------\n"

if ! DBX schemas get "$ELOG_CATALOG.$ELOG_SCHEMA"; then
    DB_EXIT_ON_ERROR="PRINT_EXIT" DBX schemas create "$ELOG_SCHEMA" "$ELOG_CATALOG"
fi

export TARGET_CATALOG_SCHEMA_CREATED=""
if ! DBX schemas get "$TARGET_CATALOG.$TARGET_SCHEMA"; then

    DB_EXIT_ON_ERROR="PRINT_EXIT" DBX schemas create "$TARGET_SCHEMA" "$TARGET_CATALOG"

    if [[ -n "${DELETE_PIPELINES_AFTER_SLEEP}" ]]; then
        :
        export TARGET_CATALOG_SCHEMA_CREATED=1
        #CLEANUP nohup sleep "${DELETE_PIPELINES_AFTER_SLEEP}" && DBX schemas delete --force "$TARGET_CATALOG.$TARGET_SCHEMA" >> ~/nohup.out 2>&1 &
    fi
fi

export STAGE_CATALOG_SCHEMA_CREATED=""
if [[ "$TARGET_CATALOG.$TARGET_SCHEMA" != "$STAGING_CATALOG.$STAGING_SCHEMA" ]] && ! DBX schemas get "$STAGING_CATALOG.$STAGING_SCHEMA"; then

    DB_EXIT_ON_ERROR="PRINT_EXIT" DBX schemas create "$STAGING_SCHEMA" "$STAGING_CATALOG"

    if [[ -n "${DELETE_PIPELINES_AFTER_SLEEP}" ]]; then
        :
        export STAGE_CATALOG_SCHEMA_CREATED=1
        #CLEANUP nohup sleep "${DELETE_PIPELINES_AFTER_SLEEP}" && DBX schemas delete --force "$STAGING_CATALOG.$STAGING_SCHEMA" >> ~/nohup.out 2>&1 &
    fi
fi

# #############################################################################

echo -e "\nCreate Connection"
echo -e    "----------------\n"

# create connection and delete or update
# specs are here ${STATE[conn_create_json]} ${STATE[conn_patch_json]}
connection_spec_from_env STATE

STATE[connection_created]=""
if ! DBX connections get "$CONNECTION_NAME"; then
    DB_EXIT_ON_ERROR="PRINT_EXIT" DBX connections create --json "${STATE[conn_create_json]}"
    STATE[connection_created]=1
else
    # connections update does not update comments
    #DB_EXIT_ON_ERROR="PRINT_EXIT" DBX api patch /api/2.1/unity-catalog/connections/$(echo -n "$CONNECTION_NAME" | jq -sRr @uri) --json "${STATE[conn_patch_json]}"
    DB_EXIT_ON_ERROR="PRINT_EXIT" DBX connections update $(echo -n "$CONNECTION_NAME" | jq -sRr @uri) --json "${STATE[conn_patch_json]}"
fi

# sometime in 2026, connection_name is used and not connection_id
CONNECTION_ID=$(jq -r '.connection_id' /tmp/dbx_stdout.$$)
STATE[CONNECTION_ID]="${CONNECTION_ID}"
export CONNECTION_ID

# #############################################################################

echo -e "\nCreate Gateway Pipeline"
echo -e   "-----------------------\n"

# Ensure optional cluster/env knobs are exported for jq env.* (empty = omit key)
export GATEWAY_DRIVER_POOL="${GATEWAY_DRIVER_POOL:-}"
export GATEWAY_WORKER_POOL="${GATEWAY_WORKER_POOL:-}"
export GATEWAY_DRIVER_NODE="${GATEWAY_DRIVER_NODE:-}"
export GATEWAY_WORKER_NODE="${GATEWAY_WORKER_NODE:-}"
export GATEWAY_MIN_WORKERS="${GATEWAY_MIN_WORKERS:-}"
export GATEWAY_MAX_WORKERS="${GATEWAY_MAX_WORKERS:-}"
export REMOVE_AFTER="${REMOVE_AFTER:-}"
export PUBLISH_EVENT_LOG="${PUBLISH_EVENT_LOG:-}"
export GATEWAY_PIPELINE_ID="${GATEWAY_PIPELINE_ID:-}"
export ELOG_CATALOG ELOG_SCHEMA
export COMPUTE_GATEWAY CDC_QBC

gw_spec="$(jq -n '
  {
    name: env.GATEWAY_PIPELINE_NAME,
    continuous: env.GATEWAY_PIPELINE_CONTINUOUS,
    development: (env.PIPELINE_DEV_MODE == "true"),
    gateway_definition: {
      connection_name: env.CONNECTION_NAME,
      gateway_storage_catalog: env.STAGING_CATALOG,
      gateway_storage_schema: env.STAGING_SCHEMA,
      gateway_storage_name: env.GATEWAY_PIPELINE_NAME
    },
    clusters: [
      {
        label: "updates",
        spark_conf: {"gateway.logging.level": "DEBUG"}
      }
      | (if env.GATEWAY_DRIVER_POOL != "" then . + {driver_instance_pool_id: env.GATEWAY_DRIVER_POOL} else . end)
      | (if env.GATEWAY_WORKER_POOL != "" then . + {instance_pool_id: env.GATEWAY_WORKER_POOL} else . end)
      | (if env.GATEWAY_DRIVER_NODE != "" then . + {driver_node_type_id: env.GATEWAY_DRIVER_NODE} else . end)
      | (if env.GATEWAY_WORKER_NODE != "" then . + {node_type_id: env.GATEWAY_WORKER_NODE} else . end)
      | (if (env.GATEWAY_MIN_WORKERS != "" and env.GATEWAY_MAX_WORKERS != "")
         then . + {autoscale: {min_workers: (env.GATEWAY_MIN_WORKERS|tonumber), max_workers: (env.GATEWAY_MAX_WORKERS|tonumber)}}
         else . end)
    ]
  }
  | (if env.REMOVE_AFTER != "" then . + {tags: {RemoveAfter: env.REMOVE_AFTER}} else . end)
  | (if env.PUBLISH_EVENT_LOG != "" then . + {
        event_log: {
          catalog: env.ELOG_CATALOG,
          schema: env.ELOG_SCHEMA,
          name: ("ingestion_elog_" + ((env.GATEWAY_PIPELINE_ID // "") | gsub("-"; "_")))
        }
      } else . end)
  | (if env.COMPUTE_GATEWAY == "serverless" then . + {serverless: true}
     elif env.COMPUTE_GATEWAY == "classic" then . + {serverless: false}
     else . end)
  | (if env.COMPUTE_GATEWAY == "serverless" then del(.clusters) else . end)
')"

GATEWAY_EVENT_LOG="event_log_${GATEWAY_PIPELINE_NAME}"

# Only the "cdc" architecture uses a separate gateway pipeline.
# "qbc" and "cdc_single_pipeline" ingest directly from the connection.
if [[ "$CDC_QBC" == "cdc" ]]; then
    DB_EXIT_ON_ERROR="PRINT_EXIT"  DBX pipelines create --json "$gw_spec"

    GATEWAY_PIPELINE_ID="$(jq -r '.pipeline_id' /tmp/dbx_stdout.$$)"
    export GATEWAY_PIPELINE_ID

    if [[ -n "${STOP_AFTER_SLEEP}" ]]; then 
        :
        #CLEANUP nohup sleep "${STOP_AFTER_SLEEP}" && DBX pipelines stop "$GATEWAY_PIPELINE_ID">> ~/nohup.out 2>&1 &
        nohup sleep "${STOP_AFTER_SLEEP}" && db_replication_cleanup "$GATEWAY_PIPELINE_ID">> ~/nohup.out 2>&1 &
    fi

    if [[ -z "${STOP_AFTER_SLEEP}" ]] && [[ -n "${DELETE_PIPELINES_AFTER_SLEEP}" ]]; then
        :
        #CLEANUP nohup sleep "${DELETE_PIPELINES_AFTER_SLEEP}" && DBX pipelines delete "$GATEWAY_PIPELINE_ID"  >> ~/nohup.out 2>&1 &
        nohup sleep "${STOP_AFTER_SLEEP}" && db_replication_cleanup "$GATEWAY_PIPELINE_ID">> ~/nohup.out 2>&1 &
    fi
else
    echo "CDC_QBC=${CDC_QBC}: skipping separate gateway pipeline (direct-from-connection ingestion)"
    export GATEWAY_PIPELINE_ID=""
fi

# #############################################################################

echo -e "\nCreate Ingestion Pipeline"
echo -e   "-------------------------\n"

export SCD_TYPE="${SCD_TYPE:-}"
export INGESTION_PIPELINE_ID="${INGESTION_PIPELINE_ID:-}"
export SOURCE_TYPE DB_CATALOG DB_SCHEMA TARGET_CATALOG TARGET_SCHEMA
export INGESTION_PIPELINE_NAME INGESTION_PIPELINE_CONTINUOUS PIPELINE_DEV_MODE
export COMPUTE_INGEST CONNECTION_NAME CDC_QBC CDC_CT_MODE
export GATEWAY_PIPELINE_ID PUBLISH_EVENT_LOG ELOG_CATALOG ELOG_SCHEMA
export PG_PRECREATE_SLOT_PUB="${PG_PRECREATE_SLOT_PUB:-1}"

# Shared cdc / cdc_single_pipeline (icdc) ingestion spec.
# Differs mainly by gateway_id vs connection_name (+ MANAGED_INGESTION extras for icdc).
# Objects from CDC_CT_MODE: CT=intpk, CDC=dtix, BOTH=intpk+dtix, NONE=schema.
ig_cdc_spec="$(jq -n '
  {
    name: env.INGESTION_PIPELINE_NAME,
    continuous: env.INGESTION_PIPELINE_CONTINUOUS,
    development: (env.PIPELINE_DEV_MODE == "true"),
    catalog: env.TARGET_CATALOG,
    schema: env.TARGET_SCHEMA,
    ingestion_definition: {
      source_type: env.SOURCE_TYPE,
      objects: (
        if env.CDC_CT_MODE == "NONE" then
          [
            {
              schema: (
                {
                  source_schema: env.DB_SCHEMA,
                  destination_catalog: env.TARGET_CATALOG,
                  destination_schema: env.TARGET_SCHEMA,
                  table_configuration: (
                    if env.SCD_TYPE != "" then {scd_type: env.SCD_TYPE} else {} end
                  )
                }
                | (if env.SOURCE_TYPE != "MYSQL" then . + {source_catalog: env.DB_CATALOG} else . end)
              )
            }
          ]
        else
          (if (env.CDC_CT_MODE == "CT" or env.CDC_CT_MODE == "BOTH") then
             [
               {
                 table: (
                   {
                     source_schema: env.DB_SCHEMA,
                     source_table: "intpk",
                     destination_catalog: env.TARGET_CATALOG,
                     destination_schema: env.TARGET_SCHEMA
                   }
                   | (if env.SOURCE_TYPE != "MYSQL" then . + {source_catalog: env.DB_CATALOG} else . end)
                 )
               }
             ]
           else [] end)
          + (if (env.CDC_CT_MODE == "CDC" or env.CDC_CT_MODE == "BOTH") then
             [
               {
                 table: (
                   {
                     source_schema: env.DB_SCHEMA,
                     source_table: "dtix",
                     destination_catalog: env.TARGET_CATALOG,
                     destination_schema: env.TARGET_SCHEMA
                   }
                   | (if env.SOURCE_TYPE != "MYSQL" then . + {source_catalog: env.DB_CATALOG} else . end)
                 )
               }
             ]
           else [] end)
        end
      )
    }
  }
  | (if env.CDC_QBC == "cdc" then
       .ingestion_definition += {ingestion_gateway_id: env.GATEWAY_PIPELINE_ID}
     else
       . + {
         pipeline_type: "MANAGED_INGESTION",
         configuration: {
           "pipelines.directCdc.minimumRunDurationMinutes": "1",
           "pipelines.directCdc.enableBoundedContinuousGraphExecution": true
         }
       }
       | .ingestion_definition += {connection_name: env.CONNECTION_NAME, connector_type: "CDC"}
     end)
  | (if env.SOURCE_TYPE == "POSTGRESQL" and env.PG_PRECREATE_SLOT_PUB == "1" then
       .ingestion_definition += {
         source_configurations: [
           {
             catalog: {
               source_catalog: env.DB_CATALOG,
               postgres: {
                 slot_config: {
                   slot_name: env.DB_SCHEMA,
                   publication_name: (env.DB_SCHEMA + "_pub")
                 }
               }
             }
           }
         ]
       }
     else . end)
  | (if env.PUBLISH_EVENT_LOG != "" then . + {
        event_log: {
          catalog: env.ELOG_CATALOG,
          schema: env.ELOG_SCHEMA,
          name: ("ingestion_elog_" + ((env.INGESTION_PIPELINE_ID // "") | gsub("-"; "_")))
        }
      } else . end)
  | (if env.CDC_QBC == "cdc_single_pipeline" then
       if env.COMPUTE_INGEST == "serverless" then . + {serverless: true}
       else . + {serverless: false} end
     elif env.COMPUTE_INGEST == "serverless" then . + {serverless: true}
     elif env.COMPUTE_INGEST == "classic" then . + {serverless: false}
     else . end)
')"

# qbc: query-based ingestion. Requires a primary key, so intpk only.
# Direct from connection (no gateway); continuous is not supported for qbc.
ig_qbc_spec="$(jq -n '
  {
    name: env.INGESTION_PIPELINE_NAME,
    continuous: false,
    development: (env.PIPELINE_DEV_MODE == "true"),
    catalog: env.TARGET_CATALOG,
    schema: env.TARGET_SCHEMA,
    ingestion_definition: {
      connection_name: env.CONNECTION_NAME,
      source_type: env.SOURCE_TYPE,
      objects: [
        {
          table: (
            {
              source_schema: env.DB_SCHEMA,
              source_table: "intpk",
              destination_catalog: env.TARGET_CATALOG,
              destination_schema: env.TARGET_SCHEMA,
              table_configuration: {
                scd_type: "SCD_TYPE_1",
                query_based_connector_config: { cursor_columns: ["dt"] }
              }
            }
            | (if env.SOURCE_TYPE != "MYSQL" then . + {source_catalog: env.DB_CATALOG} else . end)
          )
        }
      ]
    }
  }
  | (if env.PUBLISH_EVENT_LOG != "" then . + {
        event_log: {
          catalog: env.ELOG_CATALOG,
          schema: env.ELOG_SCHEMA,
          name: ("ingestion_elog_" + ((env.INGESTION_PIPELINE_ID // "") | gsub("-"; "_")))
        }
      } else . end)
  | (if env.COMPUTE_INGEST == "serverless" then . + {serverless: true}
     elif env.COMPUTE_INGEST == "classic" then . + {serverless: false}
     else . end)
')"

INGESTION_EVENT_LOG="event_log_${INGESTION_PIPELINE_NAME}"

case "${CDC_QBC}" in
    "cdc"|"cdc_single_pipeline")
        case "${CDC_CT_MODE}" in
            "BOTH"|"CT"|"CDC"|"NONE") ;;
            *)
                echo "CDC_CT_MODE=${CDC_CT_MODE} must be BOTH|CT|CDC|NONE" >&2
                return 1
            ;;
        esac
        echo "creating ${CDC_QBC} ingestion pipeline (CDC_CT_MODE=${CDC_CT_MODE})"
        DB_EXIT_ON_ERROR="PRINT_EXIT" DBX pipelines create --json "$ig_cdc_spec"
    ;;
    "qbc")
        echo "qbc: query-based ingestion of intpk (requires primary key)"
        DB_EXIT_ON_ERROR="PRINT_EXIT" DBX pipelines create --json "$ig_qbc_spec"
    ;;
    *)
        echo "CDC_QBC=${CDC_QBC} must be cdc|qbc|cdc_single_pipeline"
        return 1
    ;;
esac

INGESTION_PIPELINE_ID=$(jq -r '.pipeline_id' /tmp/dbx_stdout.$$)
export INGESTION_PIPELINE_ID

if [[ -n "${STOP_AFTER_SLEEP}" ]]; then 
    :
    #CLEANUP nohup sleep "${STOP_AFTER_SLEEP}" && DBX pipelines stop "$INGESTION_PIPELINE_ID" >> ~/nohup.out 2>&1 &
fi
if [[ -n "${DELETE_PIPELINES_AFTER_SLEEP}" ]]; then
    :
    #CLEANUP nohup sleep "${DELETE_PIPELINES_AFTER_SLEEP}" && DBX pipelines delete "$INGESTION_PIPELINE_ID" >> ~/nohup.out 2>&1 &
fi

# start if not cont
if [[ "$INGESTION_PIPELINE_CONTINUOUS" == "false" ]]; then 
    DB_EXIT_ON_ERROR="PRINT_EXIT" DBX pipelines start-update "$INGESTION_PIPELINE_ID"
fi

# #############################################################################

echo -e "\nCreate Ingestion Pipeline Trigger Jobs"
echo -e   "--------------------------------------\n"

JOBS_START_MIN_PAST_HOUR="$(( ( RANDOM % 5 ) + 1 ))"

if (( INGESTION_PIPELINE_MIN_TRIGGER >= 60 )); then
    CRON_MIN_TRIGGER='0'
    CRON_HRS_TRIGGER=$(( INGESTION_PIPELINE_MIN_TRIGGER / 60 ))
else
    CRON_MIN_TRIGGER="$INGESTION_PIPELINE_MIN_TRIGGER"
    CRON_HRS_TRIGGER='*'
fi

export JOBS_START_MIN_PAST_HOUR CRON_MIN_TRIGGER CRON_HRS_TRIGGER
export JOBS_PERFORMANCE_MODE
export INGESTION_JOB_ID="${INGESTION_JOB_ID:-}"

jobs_spec="$(jq -n '
  {
    name: env.INGESTION_PIPELINE_NAME,
    performance_target: env.JOBS_PERFORMANCE_MODE,
    schedule: {
      timezone_id: "UTC",
      quartz_cron_expression: (
        "0 " + env.JOBS_START_MIN_PAST_HOUR + "/" + env.CRON_MIN_TRIGGER
        + " " + env.CRON_HRS_TRIGGER + " * * ?"
      )
    },
    tasks: [
      {
        task_key: "run_dlt",
        pipeline_task: {pipeline_id: env.INGESTION_PIPELINE_ID}
      }
    ]
  }
  | (if env.REMOVE_AFTER != "" then . + {tags: {RemoveAfter: env.REMOVE_AFTER}} else . end)
')"

# 3 minutes past hour, run every 5 minutes
DB_EXIT_ON_ERROR="PRINT_EXIT" DBX jobs create --json "$jobs_spec"

INGESTION_JOB_ID=$(jq -r '.job_id' /tmp/dbx_stdout.$$)
export INGESTION_JOB_ID

# print UI URL
if [[ -n "${STOP_AFTER_SLEEP}" ]]; then 
    :
    #CLEANUP nohup sleep "${STOP_AFTER_SLEEP}" && DBX jobs delete "$INGESTION_JOB_ID" >> ~/nohup.out 2>&1 &
fi
if [[ -z "${STOP_AFTER_SLEEP}" ]] && [[ -n "${DELETE_PIPELINES_AFTER_SLEEP}" ]]; then
    :
    #CLEANUP nohup sleep "${DELETE_PIPELINES_AFTER_SLEEP}" && DBX jobs delete "$INGESTION_JOB_ID" >> ~/nohup.out 2>&1 &
fi


# #############################################################################

echo -e "\nPermission Gateway, Ingestion, Jobs for debug"
echo -e   "---------------------------------------------\n"

jobs_pipelines_permission="$(jq -n '{
  access_control_list: [
    {user_name: env.DBX_USERNAME, permission_level: "IS_OWNER"},
    {group_name: "users", permission_level: "CAN_MANAGE"}
  ]
}')"

if [[ -n "$GATEWAY_PIPELINE_ID"  ]]; then 
    DB_EXIT_ON_ERROR="PRINT_EXIT" DBX permissions update pipelines "$GATEWAY_PIPELINE_ID"   --json "$jobs_pipelines_permission"
fi
DB_EXIT_ON_ERROR="PRINT_EXIT" DBX permissions update pipelines "$INGESTION_PIPELINE_ID" --json "$jobs_pipelines_permission"
DB_EXIT_ON_ERROR="PRINT_EXIT" DBX permissions update jobs      "$INGESTION_JOB_ID"      --json "$jobs_pipelines_permission" 

# #############################################################################

echo -e "\n Start workload"
echo -e   "---------------\n"

_lg_started=0
if [[ ! -z "$sql_dml_generator" ]] && [[ $DML_INTERVAL_SEC -gt 0 ]]; then
    if [[ -n "${LOAD_GENERATOR_PID:-}" ]] && kill -0 "$LOAD_GENERATOR_PID" 2>/dev/null; then
        echo "Load Generator: already running with PID=$LOAD_GENERATOR_PID; not starting another."
    else
        if [[ -n "${LOAD_GENERATOR_PID:-}" ]]; then
            echo "Load Generator: PID=$LOAD_GENERATOR_PID is no longer running; restarting."
        fi
        SQLCLI >/dev/null 2>&1 <<< $(echo "$sql_dml_generator") &
        export LOAD_GENERATOR_PID=$!
        _lg_started=1
    fi
else
    export LOAD_GENERATOR_PID=""
fi

if [[ "$_lg_started" -eq 1 ]]; then
    if [[ -n "${STOP_AFTER_SLEEP}" ]]; then
        nohup sleep "${STOP_AFTER_SLEEP}" && kill -9 "$LOAD_GENERATOR_PID" >> ~/nohup.out 2>&1 &
    fi
    if [[ -z "${STOP_AFTER_SLEEP}" ]] && [[ -n "${DELETE_PIPELINES_AFTER_SLEEP}" ]]; then
        nohup sleep "${DELETE_PIPELINES_AFTER_SLEEP}" && kill -9 "$LOAD_GENERATOR_PID" >> ~/nohup.out 2>&1 &
    fi
    echo "Load Generator: started with PID=$LOAD_GENERATOR_PID."
    echo ""
fi
unset _lg_started


# #############################################################################

echo -e "\n Cleanup job - only show up in Runs UI Interface"
echo -e    "----------------------------------------------\n"

if ! DBX workspace list $DBX_WORKSPACE_PATH/copy_event_log.ipynb; then
    DBX workspace mkdirs $DBX_WORKSPACE_PATH
    if [[ -f ./bin/copy_event_log.ipynb ]]; then
        DBX workspace import $DBX_WORKSPACE_PATH/copy_event_log.ipynb --file ./bin/copy_event_log.ipynb --language PYTHON --format JUPYTER --overwrite
    else
        wget -qO- https://raw.githubusercontent.com/rsleedbx/lakeflow_connect/refs/heads/main/bin/copy_event_log.ipynb > /tmp/copy_event_log.ipynb.$$
        DBX workspace import $DBX_WORKSPACE_PATH/copy_event_log.ipynb --file /tmp/copy_event_log.ipynb.$$ --language PYTHON --format JUPYTER --overwrite
    fi
fi

get_cleanup_job_json() {
    local ACTION_NAME=${1:-stop}
    local CONNECTION_NAME_FOR_CLEANUP=${CONNECTION_NAME}

    if [[ -z "$DELETE_DB_AFTER_SLEEP" ]] && [[ -z "${STATE[connection_created]}" ]]; then
        CONNECTION_NAME_FOR_CLEANUP=""
    fi

    ACTION_NAME="$ACTION_NAME" \
    CONNECTION_NAME="$CONNECTION_NAME_FOR_CLEANUP" \
    CONNECTION_CREATED="${STATE[connection_created]:-}" \
    STAGE_CATALOG_SCHEMA_CREATED="${STAGE_CATALOG_SCHEMA_CREATED:-}" \
    TARGET_CATALOG_SCHEMA_CREATED="${TARGET_CATALOG_SCHEMA_CREATED:-}" \
    jq -n '
      {
        name: env.CLEANUP_JOB_NAME,
        tasks: [{
          task_key: "my_notebook_task",
          notebook_task: {
            notebook_path: (env.DBX_WORKSPACE_PATH + "/copy_event_log.ipynb"),
            base_parameters: {
              action_name: env.ACTION_NAME,
              connection_name: (env.CONNECTION_NAME // ""),
              gateway_pipeline_name: env.GATEWAY_PIPELINE_NAME,
              gateway_pipeline_id: env.GATEWAY_PIPELINE_ID,
              ingestion_pipeline_name: env.INGESTION_PIPELINE_NAME,
              ingestion_pipeline_id: env.INGESTION_PIPELINE_ID,
              target_catalog: env.TARGET_CATALOG,
              target_schema: env.TARGET_SCHEMA,
              stage_catalog: env.STAGING_CATALOG,
              stage_schema: env.STAGING_SCHEMA,
              elog_catalog: env.ELOG_CATALOG,
              elog_schema: env.ELOG_SCHEMA,
              job_name: env.INGESTION_PIPELINE_NAME,
              job_id: env.INGESTION_JOB_ID,
              stage_created: (env.STAGE_CATALOG_SCHEMA_CREATED // ""),
              target_created: (env.TARGET_CATALOG_SCHEMA_CREATED // ""),
              connection_created: (env.CONNECTION_CREATED // "")
            },
            compute_spec: {kind: "serverless"}
          }
        }]
      }
    '
}

if [[ -n "${STOP_AFTER_SLEEP}" ]]; then 
    nohup sleep "${STOP_AFTER_SLEEP}" && \
        DBX jobs submit --run-name "${CLEANUP_JOB_NAME}_stop" --no-wait --json "$(get_cleanup_job_json stop)" >> ~/nohup.out 2>&1 &
fi
if [[ -n "${DELETE_PIPELINES_AFTER_SLEEP}" ]]; then
    nohup sleep "${DELETE_PIPELINES_AFTER_SLEEP}" && \
        DBX jobs submit --run-name "${CLEANUP_JOB_NAME}_delete" --no-wait --json "$(get_cleanup_job_json delete)" >> ~/nohup.out 2>&1 &
fi

# #############################################################################

echo -e "\nClick on UI"
echo -e   "-----------\n"

echo -e "elog/GW Tlmy  : ${DATABRICKS_HOST_NAME}/explore/data/${ELOG_CATALOG}/${ELOG_SCHEMA}"
echo -e "Staging schema: ${DATABRICKS_HOST_NAME}/explore/data/${STAGING_CATALOG}/${STAGING_SCHEMA}"
echo -e "Target schema : ${DATABRICKS_HOST_NAME}/explore/data/${TARGET_CATALOG}/${TARGET_SCHEMA}"
echo -e "Connection    : ${DATABRICKS_HOST_NAME}/explore/connections/${CONNECTION_NAME}"
echo -e "Job           : ${DATABRICKS_HOST_NAME}/jobs/$INGESTION_JOB_ID \n"   

DB_EXIT_ON_ERROR="PRINT_EXIT" DBX pipelines list-pipelines --filter "name like '${WHOAMI}_%'"
jq --arg url "$DATABRICKS_HOST_NAME" -r 'sort_by(.name) | .[] | [ .name, .pipeline_id, .state, ($url + "/pipelines/" + .pipeline_id) ] | @tsv' /tmp/dbx_stdout.$$ 
