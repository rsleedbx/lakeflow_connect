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
# databricks URL
if ! DBX auth env; then cat /tmp/dbx_stderr.$$; return 1; fi
DATABRICKS_HOST_NAME=$(jq -r .env.DATABRICKS_HOST /tmp/dbx_stdout.$$)
# used for connection
if [[ -z "$CONNECTION_NAME" ]]; then 
    CONNECTION_NAME=$(echo "${WHOAMI}_${DB_HOST}_${DB_CATALOG}_${USER_USERNAME}" | tr [.@] _)
fi
export CONNECTION_NAME
# long name
#export GATEWAY_PIPELINE_NAME=${WHOAMI}_${NINE_CHAR_ID}_${GATEWAY_MIN_WORKERS}${GATEWAY_MAX_WORKERS}GMX_${GATEWAY_DRIVER_NODE:+${GATEWAY_DRIVER_NODE}GDN_}${GATEWAY_WORKER_NODE:+${GATEWAY_WORKER_NODE}GWN_}${INGESTION_PIPELINE_MIN_TRIGGER}TRG_${JOBS_PERFORMANCE_MODE:0:4}JPM_${PIPELINE_DEV_MODE:0:4}PDM_${DML_INTERVAL_SEC}TPS_${INITIAL_SNAPSHOT_ROWS}ROW_GW
#export INGESTION_PIPELINE_NAME=${WHOAMI}_${NINE_CHAR_ID}_${GATEWAY_MIN_WORKERS}${GATEWAY_MAX_WORKERS}GMX_${GATEWAY_DRIVER_NODE:+${GATEWAY_DRIVER_NODE}GDN_}${GATEWAY_WORKER_NODE:+${GATEWAY_WORKER_NODE}GWN_}${INGESTION_PIPELINE_MIN_TRIGGER}TRG_${JOBS_PERFORMANCE_MODE:0:4}JPM_${PIPELINE_DEV_MODE:0:4}PDM_${DML_INTERVAL_SEC}TPS_${INITIAL_SNAPSHOT_ROWS}ROW_IG
# short name
export GATEWAY_PIPELINE_NAME=${WHOAMI}_${NINE_CHAR_ID}_GW
export INGESTION_PIPELINE_NAME=${WHOAMI}_${NINE_CHAR_ID}_IG
export CLEANUP_JOB_NAME=${WHOAMI}_${NINE_CHAR_ID}_cleanup
# used for the pipelines
export TARGET_CATALOG=${TARGET_CATALOG:-"main"}
export TARGET_SCHEMA=${WHOAMI}_${NINE_CHAR_ID}
export STAGING_CATALOG=${TARGET_CATALOG}
export STAGING_SCHEMA=${TARGET_SCHEMA}
export ELOG_CATALOG=${ELOG_CATALOG:-"main"}
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
# the echo is to make the if statement work

STATE[conn_create_json]=$(yq -o json <<EOF
name: $CONNECTION_NAME
connection_type: $CONNECTION_TYPE
comment: '{"catalog": "$DB_CATALOG", "schema": "$DB_SCHEMA", "secrets": {"scope": "$SECRETS_SCOPE", "key": "$DB_HOST"}}'
options: 
    host: $DB_HOST_FQDN
    port: $DB_PORT
    user: $USER_USERNAME
    password: $USER_PASSWORD
    $(if [[ "$CONNECTION_TYPE" == "SQLSERVER" ]]; then printf "trustServerCertificate: true"; fi)
EOF
)
STATE[conn_patch_json]=$(echo "${STATE[conn_create_json]}" | jq 'del(.connection_type)')

if ! DBX connections get "$CONNECTION_NAME"; then
    DB_EXIT_ON_ERROR="PRINT_EXIT" DBX connections create --json "${STATE[conn_create_json]}"
    STATE[connection_created]=1
else
    # connections update does not update comments
    DB_EXIT_ON_ERROR="PRINT_EXIT" DBX api patch /api/2.1/unity-catalog/connections/"$CONNECTION_NAME" --json "${STATE[conn_patch_json]}"
fi

CONNECTION_ID=$(jq -r '.connection_id' /tmp/dbx_stdout.$$)
STATE[CONNECTION_ID]="${CONNECTION_ID}"
export CONNECTION_ID

return 1

# #############################################################################

if [[ -n "$REMOVE_AFTER" ]]; then
REMOVE_AFTER_TAG='
, "tags": {
    "RemoveAfter": "'"$REMOVE_AFTER"'"
}'
else
REMOVE_AFTER_TAG=''
fi

# #############################################################################

echo -e "\nCreate Gateway Pipeline"
echo -e   "-----------------------\n"

GATEWAY_EVENT_LOG="event_log_${GATEWAY_PIPELINE_NAME}"

if ! DBX pipelines create --json "$(echo '{
"name": "'"$GATEWAY_PIPELINE_NAME"'",
'${PUBLISH_EVENT_LOG:+"\"event_log\": {\"catalog\": \"$ELOG_CATALOG\",\"schema\": \"$ELOG_SCHEMA\",\"name\": \"ingestion_elog_${GATEWAY_PIPELINE_ID//-/_}\"},"}'
"clusters": [
  {"label": "updates", 
    "spark_conf": {"gateway.logging.level": "DEBUG"}
    '$([[ -n "$GATEWAY_DRIVER_POOL" ]] && echo ",\"driver_instance_pool_id\": \"${GATEWAY_DRIVER_POOL}\"")'
    '$([[ -n "$GATEWAY_WORKER_POOL" ]] && echo ",\"instance_pool_id\": \"${GATEWAY_WORKER_POOL}\"")'
    '$([[ -n "$GATEWAY_DRIVER_NODE" ]] && echo ",\"driver_node_type_id\": \"${GATEWAY_DRIVER_NODE}\"")'
    '$([[ -n "$GATEWAY_WORKER_NODE" ]] && echo ",\"node_type_id\": \"${GATEWAY_WORKER_NODE}\"")'
    '$([[ -n "$GATEWAY_MIN_WORKERS" && -n "$GATEWAY_MAX_WORKERS" ]] && echo ",\"autoscale\": { \"min_workers\": $GATEWAY_MIN_WORKERS, \"max_workers\": $GATEWAY_MAX_WORKERS}")'
  }
],
"continuous": "'"$GATEWAY_PIPELINE_CONTINUOUS"'",
"gateway_definition": {
  "connection_id": "'"$CONNECTION_ID"'",
  "gateway_storage_catalog": "'"$STAGING_CATALOG"'",
  "gateway_storage_schema": "'"$STAGING_SCHEMA"'",
  "gateway_storage_name": "'"$GATEWAY_PIPELINE_NAME"'" 
}
'$REMOVE_AFTER_TAG'
}')"; then
    cat /tmp/dbx_stderr.$$
    return 1
fi
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

# #############################################################################

echo -e "\nCreate Ingestion Pipeline"
echo -e   "-------------------------\n"

INGESTION_EVENT_LOG="event_log_${INGESTION_PIPELINE_NAME}"

case "${CDC_CT_MODE}" in 
"BOTH"|"NONE") 
echo "enabling replication on the schema"
if ! DBX pipelines create --json "$(echo '{
"name": "'"$INGESTION_PIPELINE_NAME"'",
'${PUBLISH_EVENT_LOG:+"\"event_log\": {\"catalog\": \"$ELOG_CATALOG\",\"schema\": \"$ELOG_SCHEMA\",\"name\": \"ingestion_elog_${INGESTION_PIPELINE_ID//-/_}\"},"}' 
"continuous": "'"$INGESTION_PIPELINE_CONTINUOUS"'",
"development": "'"$PIPELINE_DEV_MODE"'",
"ingestion_definition": {
  "ingestion_gateway_id": "'"$GATEWAY_PIPELINE_ID"'",
  "source_type": "'"$SOURCE_TYPE"'",
  "objects": [
     {"schema": {
        '$(if [[ "$SOURCE_TYPE" != "MYSQL" ]]; then echo "\"source_catalog\": \"$DB_CATALOG\",";fi)'
        "source_schema": "'"$DB_SCHEMA"'",
        "destination_catalog": "'"$TARGET_CATALOG"'",
        "destination_schema": "'"$TARGET_SCHEMA"'",
        "table_configuration": {
        '$(if [[ -n "$SCD_TYPE" ]]; then echo "\"scd_type\": \"${SCD_TYPE}\"";fi)'
        }}}
    ]
  }
'$REMOVE_AFTER_TAG'
}')"; then
    cat /tmp/dbx_stderr.$$
    return 1
fi
;;
"CT") 
echo "enabling replication on the intpk table"
if ! DBX pipelines create --json "$(echo '{
"name": "'"$INGESTION_PIPELINE_NAME"'",
'${PUBLISH_EVENT_LOG:+"\"event_log\": {\"catalog\": \"$ELOG_CATALOG\",\"schema\": \"$ELOG_SCHEMA\",\"name\": \"ingestion_elog_${INGESTION_PIPELINE_ID//-/_}\"},"}' 
"continuous": "'"$INGESTION_PIPELINE_CONTINUOUS"'",
"development": "'"$PIPELINE_DEV_MODE"'",
"ingestion_definition": {
  "ingestion_gateway_id": "'"$GATEWAY_PIPELINE_ID"'",
  "source_type": "'"$SOURCE_TYPE"'",
  "objects": [
     {"table": {
        '$(if [[ "$SOURCE_TYPE" != "MYSQL" ]]; then echo "\"source_catalog\": \"$DB_CATALOG\",";fi)'
        "source_schema": "'"$DB_SCHEMA"'",
        "source_table": "intpk",
        "destination_catalog": "'"$TARGET_CATALOG"'",
        "destination_schema": "'"$TARGET_SCHEMA"'"
        }}
    ]
  }
'$REMOVE_AFTER_TAG'
}')"    ; then
    cat /tmp/dbx_stderr.$$
    return 1
fi
;;
"CDC") 
echo "enabling replication on the dtix table"
if ! DBX pipelines create --json "$(echo '{
"name": "'"$INGESTION_PIPELINE_NAME"'",
'${PUBLISH_EVENT_LOG:+"\"event_log\": {\"catalog\": \"$ELOG_CATALOG\",\"schema\": \"$ELOG_SCHEMA\",\"name\": \"ingestion_elog_${INGESTION_PIPELINE_ID//-/_}\"},"}' 
"performance_target": "'"$JOBS_PERFORMANCE_MODE"'",
"continuous": "'"$INGESTION_PIPELINE_CONTINUOUS"'",
"development": "'"$PIPELINE_DEV_MODE"'",
"ingestion_definition": {
  "ingestion_gateway_id": "'"$GATEWAY_PIPELINE_ID"'",
  "source_type": "'"$SOURCE_TYPE"'",
  "objects": [
     {"table": {
        '$(if [[ "$SOURCE_TYPE" != "MYSQL" ]]; then echo "\"source_catalog\": \"$DB_CATALOG\",";fi)'
        "source_schema": "'"$DB_SCHEMA"'",
        "source_table": "dtix",
        "destination_catalog": "'"$TARGET_CATALOG"'",
        "destination_schema": "'"$TARGET_SCHEMA"'"
        }}
    ]
  }
'$REMOVE_AFTER_TAG'
}')"; then
    cat /tmp/dbx_stderr.$$
    return 1
fi
;;
*)
echo "CDC_CT_MODE=${CDC_CT_MODE} must be BOTH|CT|CDC|NONE"
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
if [[ "$INGESTION_PIPELINE_CONTINUOUS" == 'false' ]]; then 
    if ! DBX  pipelines start-update "$INGESTION_PIPELINE_ID"; then
        cat /tmp/dbx_stderr.$$
        return 1    
    fi
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

# 3 minutes past hour, run every 5 minutes
if ! DBX jobs create --json "$(echo '{
"name":"'"$INGESTION_PIPELINE_NAME"'",
"performance_target": "'"$JOBS_PERFORMANCE_MODE"'",
"schedule": {"timezone_id":"UTC", "quartz_cron_expression": "0 '$JOBS_START_MIN_PAST_HOUR'/'$CRON_MIN_TRIGGER' '$CRON_HRS_TRIGGER' * * ?"},
"tasks": [ {
    "task_key":"run_dlt", 
    "pipeline_task":{"pipeline_id":"'"$INGESTION_PIPELINE_ID"'"} 
  } 
]
'$REMOVE_AFTER_TAG'
}')"; then
    cat /tmp/dbx_stderr.$$
    return 1    
fi

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


jobs_pipelines_permission='{"access_control_list": [{"user_name": "'"$DBX_USERNAME"'","permission_level": "IS_OWNER"},{"group_name": "users","permission_level": "CAN_MANAGE"}]}'

if ! DBX permissions update pipelines "$GATEWAY_PIPELINE_ID"   --json "$jobs_pipelines_permission"; then cat /tmp/dbx_stderr.$$; return 1; fi 
if ! DBX permissions update pipelines "$INGESTION_PIPELINE_ID" --json "$jobs_pipelines_permission"; then cat /tmp/dbx_stderr.$$; return 1; fi  
if ! DBX permissions update jobs      "$INGESTION_JOB_ID"      --json "$jobs_pipelines_permission"; then cat /tmp/dbx_stderr.$$; return 1; fi  

# #############################################################################

echo -e "\n Start workload"
echo -e   "---------------\n"

if [[ ! -z "$sql_dml_generator" ]] && [[ $DML_INTERVAL_SEC -gt 0 ]]; then
    SQLCLI >/dev/null 2>&1 <<< $(echo "$sql_dml_generator") &
    export LOAD_GENERATOR_PID=$!
else
    export LOAD_GENERATOR_PID=""
fi

if [[ ! -z "$LOAD_GENERATOR_PID" ]]; then
if [[ -n "${STOP_AFTER_SLEEP}" ]]; then 
    nohup sleep "${STOP_AFTER_SLEEP}" && kill -9 "$LOAD_GENERATOR_PID" >> ~/nohup.out 2>&1 &
fi
if [[ -z "${STOP_AFTER_SLEEP}" ]] && [[ -n "${DELETE_PIPELINES_AFTER_SLEEP}" ]]; then
    nohup sleep "${DELETE_PIPELINES_AFTER_SLEEP}" && kill -9 "$LOAD_GENERATOR_PID" >> ~/nohup.out 2>&1 &
fi
echo "Load Generator: started with PID=$LOAD_GENERATOR_PID."
echo ""
fi

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
    local CONNECTION_NAME=${CONNECTION_NAME}

    if [[ -z "$DELETE_DB_AFTER_SLEEP" ]] && [[ -z "${STATE[connection_created]}" ]]; then CONNECTION_NAME=""; fi
        
    CLEANUP_JOB_JSON='{
    "name": "'${CLEANUP_JOB_NAME}'",
    "tasks": [{
        "task_key": "my_notebook_task",
        "notebook_task": {
            "notebook_path": "'$DBX_WORKSPACE_PATH'/copy_event_log.ipynb",
            "base_parameters": {
                "action_name": "'$ACTION_NAME'",
                "connection_name": "'$CONNECTION_NAME'",
                "gateway_pipeline_name": "'$GATEWAY_PIPELINE_NAME'",
                "gateway_pipeline_id": "'$GATEWAY_PIPELINE_ID'",
                "ingestion_pipeline_name": "'$INGESTION_PIPELINE_NAME'",
                "ingestion_pipeline_id": "'$INGESTION_PIPELINE_ID'",
                "target_catalog": "'"$TARGET_CATALOG"'",
                "target_schema": "'"$TARGET_SCHEMA"'",
                "stage_catalog": "'"$STAGING_CATALOG"'",
                "stage_schema": "'"$STAGING_SCHEMA"'",
                "elog_catalog": "'"$ELOG_CATALOG"'",
                "elog_schema": "'"$ELOG_SCHEMA"'",
                "job_name": "'$INGESTION_PIPELINE_NAME'",
                "job_id": "'$INGESTION_JOB_ID'",
                "stage_created": "'$STAGE_CATALOG_SCHEMA_CREATED'",
                "target_created": "'$TARGET_CATALOG_SCHEMA_CREATED'",
                connection_created: "'${STATE[connection_created]}'"
            },
            "compute_spec": {
                "kind": "serverless"
            }
        }
    }]
    }'
    echo "$CLEANUP_JOB_JSON"
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

if ! DBX pipelines list-pipelines --filter "name like '${WHOAMI}_%'"; then cat /tmp/dbx_stderr.$$; return 1; fi
jq --arg url "$DATABRICKS_HOST_NAME" -r 'sort_by(.name) | .[] | [ .name, .pipeline_id, .state, ($url + "/pipelines/" + .pipeline_id) ] | @tsv' /tmp/dbx_stdout.$$ 
