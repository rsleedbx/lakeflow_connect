#!/usr/bin/env bash

# error out when undeclared variable is used
set -u 

# must be sourced for exports to continue to the next script
if [ "$0" == "$BASH_SOURCE" ]; then
  echo "Script is being executed directly. Please run as source $0"
  exit 1
fi

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
    CONNECTION_NAME=$(echo "${WHOAMI}_${DB_HOST}_${DB_CATALOG}_${USER_USERNAME}" | tr '.@-' '_')
fi
export CONNECTION_NAME
# short name with pipeline type + compute: e.g. ..._cdc_default_GW / ..._qbc_fcon_srvless_IG
case "${CDC_QBC}" in
    "cdc") PIPELINE_TYPE_TAG="cdc" ;;
    "qbc_fcon") PIPELINE_TYPE_TAG="qbc_fcon" ;;
    "qbc_fc") PIPELINE_TYPE_TAG="qbc_fc" ;;
    "cdc_single_pipeline"|"icdc") PIPELINE_TYPE_TAG="icdc" ;;
    *)
        echo "CDC_QBC=${CDC_QBC} must be cdc|qbc_fcon|qbc_fc|cdc_single_pipeline|icdc" >&2
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
# Schema-level source (may already be set by 02_*); per-table uses DB_SCHEMA
export DB_SCHEMA_SCH="${DB_SCHEMA_SCH:-${DB_SCHEMA}_sch}"
# check access to SQL Server

# #############################################################################

echo -e "\nCreate target and staging schemas"
echo -e   "---------------------------------\n"

if ! DBX schemas get "$ELOG_CATALOG.$ELOG_SCHEMA"; then
    DB_EXIT_ON_ERROR="PRINT_EXIT" DBX schemas create "$ELOG_SCHEMA" "$ELOG_CATALOG"
fi

if ! DBX schemas get "$TARGET_CATALOG.$TARGET_SCHEMA"; then
    DB_EXIT_ON_ERROR="PRINT_EXIT" DBX schemas create "$TARGET_SCHEMA" "$TARGET_CATALOG"
fi

if [[ "$TARGET_CATALOG.$TARGET_SCHEMA" != "$STAGING_CATALOG.$STAGING_SCHEMA" ]] && ! DBX schemas get "$STAGING_CATALOG.$STAGING_SCHEMA"; then
    DB_EXIT_ON_ERROR="PRINT_EXIT" DBX schemas create "$STAGING_SCHEMA" "$STAGING_CATALOG"
fi

# #############################################################################

echo -e "\nCreate Connection"
echo -e    "----------------\n"

# specs: STATE[conn_create_json] / STATE[conn_patch_json] (same options; patch omits connection_type)
connection_spec_from_env STATE
connection_create_or_replace STATE
# CONNECTION_ID and STATE[connection_created] set by connection_create_or_replace

if [[ "${CDC_QBC}" == "qbc_fc" ]]; then
    echo -e "\nCreate Foreign Catalog"
    echo -e   "----------------------\n"
    foreign_catalog_create_or_replace STATE
    export FOREIGN_CATALOG_NAME="${STATE[FOREIGN_CATALOG_NAME]}"
    echo -e "Foreign catalog: ${DATABRICKS_HOST_NAME}/explore/data/${FOREIGN_CATALOG_NAME}\n"
fi

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
# "qbc_fcon" and "cdc_single_pipeline" ingest directly from the connection.
if [[ "$CDC_QBC" == "cdc" ]]; then
    DB_EXIT_ON_ERROR="PRINT_EXIT"  DBX pipelines create --json "$gw_spec"

    GATEWAY_PIPELINE_ID="$(jq -r '.pipeline_id' /tmp/dbx_stdout.$$)"
    export GATEWAY_PIPELINE_ID
else
    echo "CDC_QBC=${CDC_QBC}: skipping separate gateway pipeline (direct-from-connection ingestion)"
    export GATEWAY_PIPELINE_ID=""
fi

# #############################################################################

echo -e "\nCreate Ingestion Pipeline"
echo -e   "-------------------------\n"

# Postgres CDC: per-pipeline slot/publication named ${WHOAMI}_${NINE_CHAR_ID}
export PG_SLOT_NAME="${PG_SLOT_NAME:-}"
export PG_PUBLICATION_NAME="${PG_PUBLICATION_NAME:-}"
if [[ "${SOURCE_TYPE}" == "POSTGRESQL" ]] \
  && [[ "${PG_PRECREATE_SLOT_PUB:-1}" == "1" ]] \
  && [[ "${CDC_QBC}" == "cdc" || "${CDC_QBC}" == "icdc" || "${CDC_QBC}" == "cdc_single_pipeline" ]]; then
  if ! declare -F db_setup_pipeline_slot_pub >/dev/null; then
    # shellcheck source=postgres/02_postgres_configure.sh
    PG_CONFIGURE_MAIN=0 source "${_LFC_REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]:-.}")" && pwd)}/postgres/02_postgres_configure.sh" \
      || { echo "ERROR: could not load db_setup_pipeline_slot_pub" >&2; kill -INT $$; }
  fi
  if ! db_setup_pipeline_slot_pub "${NINE_CHAR_ID}"; then
    echo "ERROR: db_setup_pipeline_slot_pub ${NINE_CHAR_ID} failed" >&2
    kill -INT $$
  fi
  export PG_SLOT_NAME="${WHOAMI}_${NINE_CHAR_ID}"
  export PG_PUBLICATION_NAME="${PG_SLOT_NAME}_pub"
fi

export INGESTION_PIPELINE_ID="${INGESTION_PIPELINE_ID:-}"
export SOURCE_TYPE DB_CATALOG DB_SCHEMA DB_SCHEMA_SCH
export TARGET_CATALOG TARGET_SCHEMA
export INGESTION_PIPELINE_NAME INGESTION_PIPELINE_CONTINUOUS PIPELINE_DEV_MODE
export COMPUTE_INGEST CONNECTION_NAME CDC_QBC
export GATEWAY_PIPELINE_ID PUBLISH_EVENT_LOG ELOG_CATALOG ELOG_SCHEMA
export PG_PRECREATE_SLOT_PUB="${PG_PRECREATE_SLOT_PUB:-1}"
export PG_SLOT_NAME PG_PUBLICATION_NAME
export FOREIGN_CATALOG_NAME="${FOREIGN_CATALOG_NAME:-${CONNECTION_NAME}}"

# Hardcoded SCD matrix (no TABLE_SCD_TYPE); see README-demo-matrix.md Constraints
# append_only is QBC-only; CDC/ICDC use scd_type2 for dtix
export CDC_CT_MODE="${CDC_CT_MODE:-BOTH}"
case "${CDC_QBC}" in
  qbc_fc|qbc_fcon)
    TABLE_SCD_ENTRIES_JSON='[{"table":"intpk","mode":"scd_type1"},{"table":"strpk","mode":"scd_type2"},{"table":"dtix","mode":"append_only"}]'
    ;;
  cdc|icdc|cdc_single_pipeline)
    if [[ "${SOURCE_TYPE}" == "SQLSERVER" && "${CDC_CT_MODE}" == "CT" ]]; then
      TABLE_SCD_ENTRIES_JSON='[{"table":"intpk","mode":"scd_type1"},{"table":"strpk","mode":"scd_type1"},{"table":"dtix","mode":"scd_type1"}]'
    else
      # MySQL / Postgres CDC; SQL Server BOTH/CDC — no append_only outside QBC
      TABLE_SCD_ENTRIES_JSON='[{"table":"intpk","mode":"scd_type1"},{"table":"strpk","mode":"scd_type2"},{"table":"dtix","mode":"scd_type2"}]'
    fi
    ;;
  *)
    TABLE_SCD_ENTRIES_JSON='[{"table":"intpk","mode":"scd_type1"},{"table":"strpk","mode":"scd_type2"},{"table":"dtix","mode":"scd_type2"}]'
    ;;
esac
export TABLE_SCD_ENTRIES_JSON

# Source catalog on objects: foreign catalog for qbc_fc; DB_CATALOG otherwise (omit for MySQL).
if [[ "${CDC_QBC}" == "qbc_fc" ]]; then
    export IG_SOURCE_CATALOG="${FOREIGN_CATALOG_NAME}"
elif [[ "${SOURCE_TYPE}" == "MYSQL" ]]; then
    export IG_SOURCE_CATALOG=""
else
    export IG_SOURCE_CATALOG="${DB_CATALOG}"
fi

# Shared objects for every CDC_QBC mode:
#   - schema-level from DB_SCHEMA_SCH (*_sch tables)
#   - per-table SCD from DB_SCHEMA (intpk/strpk/dtix via hardcoded TABLE_SCD_ENTRIES_JSON)
IG_OBJECTS_JSON="$(jq -n '
  def table_cfg(mode):
    (if mode == "scd_type1" then
      {scd_type: "SCD_TYPE_1", primary_keys: ["pk"]}
    elif mode == "scd_type2" then
      {scd_type: "SCD_TYPE_2", primary_keys: ["pk"]}
    elif mode == "append_only" then
      {scd_type: "APPEND_ONLY"}
    else
      {scd_type: "SCD_TYPE_1", primary_keys: ["pk"]}
    end)
    | if (env.CDC_QBC == "qbc_fc" or env.CDC_QBC == "qbc_fcon") then
        # QBC: cursor on every SCD mode (scd_type1 / scd_type2 / append_only)
        . + {query_based_connector_config: {cursor_columns: ["dt"]}}
      else .
      end;
  def with_src_catalog:
    if env.IG_SOURCE_CATALOG != "" then . + {source_catalog: env.IG_SOURCE_CATALOG} else . end;
  [
    {
      schema: (
        {
          source_schema: env.DB_SCHEMA_SCH,
          destination_catalog: env.TARGET_CATALOG,
          destination_schema: env.TARGET_SCHEMA
        } | with_src_catalog
      )
    }
  ]
  + (
      (env.TABLE_SCD_ENTRIES_JSON | fromjson)
      | map(
          {
            table: (
              {
                source_schema: env.DB_SCHEMA,
                source_table: .table,
                destination_catalog: env.TARGET_CATALOG,
                destination_schema: env.TARGET_SCHEMA,
                table_configuration: table_cfg(.mode)
              } | with_src_catalog
            )
          }
        )
    )
')"
export IG_OBJECTS_JSON

# One pipeline spec: shared objects; CDC_QBC only changes the connector envelope
ig_spec="$(jq -n '
  {
    name: env.INGESTION_PIPELINE_NAME,
    development: (env.PIPELINE_DEV_MODE == "true"),
    catalog: env.TARGET_CATALOG,
    schema: env.TARGET_SCHEMA,
    ingestion_definition: {
      objects: (env.IG_OBJECTS_JSON | fromjson)
    }
  }
  | (if env.CDC_QBC == "cdc" then
       . + {continuous: env.INGESTION_PIPELINE_CONTINUOUS}
       | .ingestion_definition += {
           source_type: env.SOURCE_TYPE,
           ingestion_gateway_id: env.GATEWAY_PIPELINE_ID
         }
     elif (env.CDC_QBC == "cdc_single_pipeline" or env.CDC_QBC == "icdc") then
       . + {
         continuous: env.INGESTION_PIPELINE_CONTINUOUS,
         pipeline_type: "MANAGED_INGESTION",
         configuration: {
           "pipelines.directCdc.minimumRunDurationMinutes": "1",
           "pipelines.directCdc.enableBoundedContinuousGraphExecution": true
         }
       }
       | .ingestion_definition += {
           source_type: env.SOURCE_TYPE,
           connection_name: env.CONNECTION_NAME,
           connector_type: "CDC"
         }
     elif env.CDC_QBC == "qbc_fcon" then
       . + {continuous: false}
       | .ingestion_definition += {
           connection_name: env.CONNECTION_NAME,
           source_type: env.SOURCE_TYPE
         }
     elif env.CDC_QBC == "qbc_fc" then
       . + {continuous: false}
       | .ingestion_definition += {
           ingest_from_uc_foreign_catalog: true,
           source_type: "FOREIGN_CATALOG"
         }
     else
       .
     end)
  | (if env.SOURCE_TYPE == "POSTGRESQL" and env.PG_PRECREATE_SLOT_PUB == "1"
        and (env.PG_SLOT_NAME // "") != ""
        and (env.CDC_QBC == "cdc" or env.CDC_QBC == "cdc_single_pipeline" or env.CDC_QBC == "icdc") then
       .ingestion_definition += {
         source_configurations: [
           {
             catalog: {
               source_catalog: env.DB_CATALOG,
               postgres: {
                 slot_config: {
                   slot_name: env.PG_SLOT_NAME,
                   publication_name: env.PG_PUBLICATION_NAME
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
  | (if (env.CDC_QBC == "cdc_single_pipeline" or env.CDC_QBC == "icdc") then
       if env.COMPUTE_INGEST == "serverless" then . + {serverless: true}
       else . + {serverless: false} end
     elif env.COMPUTE_INGEST == "serverless" then . + {serverless: true}
     elif env.COMPUTE_INGEST == "classic" then . + {serverless: false}
     else . end)
')"

INGESTION_EVENT_LOG="event_log_${INGESTION_PIPELINE_NAME}"

echo "ingestion objects: schema ${DB_SCHEMA_SCH} + tables from ${DB_SCHEMA} ($(echo "${TABLE_SCD_ENTRIES_JSON}" | jq -c 'map(.table)')) → ${TARGET_SCHEMA}"
echo "creating ${CDC_QBC} ingestion pipeline"
DB_EXIT_ON_ERROR="PRINT_EXIT" DBX pipelines create --json "$ig_spec"

INGESTION_PIPELINE_ID=$(jq -r '.pipeline_id' /tmp/dbx_stdout.$$)
export INGESTION_PIPELINE_ID

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

# can_manage on job raises security alert
#DB_EXIT_ON_ERROR="PRINT_EXIT" DBX permissions update jobs      "$INGESTION_JOB_ID"      --json "$jobs_pipelines_permission" 

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
        _lg_stdout="/tmp/load_generator_stdout.$$"
        _lg_stderr="/tmp/load_generator_stderr.$$"
        : > "${_lg_stdout}"
        : > "${_lg_stderr}"
        # Do not discard streams: connect failures must be visible. PRINT_RETURN
        # surfaces RC without killing the parent shell (loop stays backgrounded).
        DB_EXIT_ON_ERROR=PRINT_RETURN \
          DB_STDOUT="${_lg_stdout}" \
          DB_STDERR="${_lg_stderr}" \
          SQLCLI <<< "$(echo "$sql_dml_generator")" &
        export LOAD_GENERATOR_PID=$!
        sleep 2
        if ! kill -0 "$LOAD_GENERATOR_PID" 2>/dev/null; then
            echo "Load Generator: failed to start (PID=$LOAD_GENERATOR_PID exited)." >&2
            [[ -s "${_lg_stderr}" ]] && cat "${_lg_stderr}" >&2
            [[ -s "${_lg_stdout}" ]] && cat "${_lg_stdout}" >&2
            export LOAD_GENERATOR_PID=""
            _lg_started=0
        else
            _lg_started=1
        fi
        unset _lg_stdout _lg_stderr
    fi
else
    export LOAD_GENERATOR_PID=""
fi

if [[ "$_lg_started" -eq 1 ]]; then
    echo "${LOAD_GENERATOR_PID}" > "/tmp/lfc_load_generator_${WHOAMI}.pid"
    echo "Load Generator: started with PID=$LOAD_GENERATOR_PID (pid file /tmp/lfc_load_generator_${WHOAMI}.pid)."
    echo ""
elif [[ -n "${LOAD_GENERATOR_PID:-}" ]] && kill -0 "$LOAD_GENERATOR_PID" 2>/dev/null; then
    echo "${LOAD_GENERATOR_PID}" > "/tmp/lfc_load_generator_${WHOAMI}.pid"
fi
unset _lg_started


# #############################################################################

echo -e "\nClick on UI"
echo -e   "-----------\n"

echo -e "elog/GW Tlmy  : ${DATABRICKS_HOST_NAME}/explore/data/${ELOG_CATALOG}/${ELOG_SCHEMA}"
echo -e "Staging schema: ${DATABRICKS_HOST_NAME}/explore/data/${STAGING_CATALOG}/${STAGING_SCHEMA}"
echo -e "Target schema : ${DATABRICKS_HOST_NAME}/explore/data/${TARGET_CATALOG}/${TARGET_SCHEMA}"
echo -e "Connection    : ${DATABRICKS_HOST_NAME}/explore/connections/${CONNECTION_NAME}"
if [[ "${CDC_QBC}" == "qbc_fc" ]]; then
    echo -e "Foreign catalog: ${DATABRICKS_HOST_NAME}/explore/data/${FOREIGN_CATALOG_NAME}"
fi
echo -e "Job           : ${DATABRICKS_HOST_NAME}/jobs/$INGESTION_JOB_ID \n"
echo -e "Teardown      : ./06_manual_delete.sh --id ${NINE_CHAR_ID}   # dry-run; add --apply to delete\n"

DB_EXIT_ON_ERROR="PRINT_EXIT" DBX pipelines list-pipelines --filter "name like '${WHOAMI}_%'"
jq --arg url "$DATABRICKS_HOST_NAME" -r 'sort_by(.name) | .[] | [ .name, .pipeline_id, .state, ($url + "/pipelines/" + .pipeline_id) ] | @tsv' /tmp/dbx_stdout.$$ 
