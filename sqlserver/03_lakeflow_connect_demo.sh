#!/usr/bin/env bash

# must be sourced for exports to continue to the next script
if [ "$0" == "$BASH_SOURCE" ]; then
  echo "Script is being executed directly. Please run as source $0"
  exit 1
fi

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
    if [[ -f ./00_lakeflow_connect_env.sh ]]; then
        source ./00_lakeflow_connect_env.sh
    else
        source <(curl -s -L https://raw.githubusercontent.com/rsleedbx/lakeflow_connect/refs/heads/sqlserver/sqlserver/00_lakeflow_connect_env.sh)
    fi
fi

# stop the resource after this 1s 1m 1h ...
export STOP_AFTER_SLEEP=${STOP_AFTER_SLEEP:-"20m"}
# uncomment if delete is also desired.  
# Tag will also be created to ensure delete happens via automation in the cloud
# export DELETE_AFTER_SLEEP=${DELETE_AFTER_SLEEP:-"120m"}
# make unique schema, pipelines, job
NINE_CHAR_ID=$(date +%s | xargs printf "%08x\n") # number of seconds since epoch in hex
export NINE_CHAR_ID
# databricks URL
DATABRICKS_HOST=$(databricks auth env | jq -r .env.DATABRICKS_HOST)
export DATABRICKS_HOST
# used for connection
CONNECTION_NAME=$(echo "${WHOAMI}_${DB_HOST_FQDN}_${USER_USERNAME}" | tr [.@] _)
export CONNECTION_NAME
export GATEWAY_PIPELINE_NAME=${WHOAMI}_${NINE_CHAR_ID}_GW
export INGESTION_PIPELINE_NAME=${WHOAMI}_${NINE_CHAR_ID}_IG
# used for the pipelines
export TARGET_CATALOG="main"
export TARGET_SCHEMA=${WHOAMI}_${NINE_CHAR_ID}
export STAGING_CATALOG=${TARGET_CATALOG}
export STAGING_SCHEMA=${TARGET_SCHEMA}
# check access to SQL Server


# #############################################################################

# create staging and target schemas
databricks schemas create "$TARGET_SCHEMA" "$TARGET_CATALOG" >/dev/null
if [[ -n "${DELETE_AFTER_SLEEP}" ]]; then
    nohup sleep "${DELETE_AFTER_SLEEP}" && databricks schemas delete "$TARGET_CATALOG.$TARGET_SCHEMA" >> ~/nohup.out 2>&1 &
fi

if [ "$STAGING_CATALOG.$STAGING_SCHEMA" != "$TARGET_CATALOG.$TARGET_SCHEMA" ]; then 
    databricks schemas create "$STAGING_SCHEMA" "$STAGING_CATALOG" >/dev/null
    if [[ -n "${DELETE_AFTER_SLEEP}" ]]; then
        nohup sleep "${DELETE_AFTER_SLEEP}" && databricks schemas delete "$STAGING_CATALOG.$STAGING_SCHEMA" >> ~/nohup.out 2>&1 &
    fi
fi

# #############################################################################

# create
conn_get_output=$(databricks connections get "$CONNECTION_NAME" 2>/dev/null)
if [[ -z "$conn_get_output" ]]; then 
  conn_output=$(databricks connections create --json '{
    "name": "'"$CONNECTION_NAME"'",
    "connection_type": "SQLSERVER",
    "options": {
      "host": "'"$DB_HOST_FQDN"'",
      "port": "'"$DB_PORT"'",
      "trustServerCertificate": "true",
      "user": "'"$USER_USERNAME"'",
      "password": "'"$USER_PASSWORD"'"
    }
  }')
else
  # in case password is updated
  conn_output=$(databricks connections update "$CONNECTION_NAME" --json '{
    "options": {
      "host": "'"$DB_HOST_FQDN"'",
      "port": "'"$DB_PORT"'",
      "trustServerCertificate": "true",
      "user": "'"$USER_USERNAME"'",
      "password": "'"$USER_PASSWORD"'"
    }
  }')
fi
# needed by the gateway pipeline
CONNECTION_ID=$(echo "$conn_output" | jq -r '.connection_id')
export CONNECTION_ID

# don't delete connection for now
connection_delete() {
if [[ -n $CONNECTION_ID ]]; then
    echo "CONNECTION_ID=$CONNECTION_ID"
    if [[ -n "${STOP_AFTER_SLEEP}" ]]; then 
        nohup sleep "${STOP_AFTER_SLEEP}" && databricks connections delete "${CONNECTION_NAME}" >> ~/nohup.out 2>&1 &
    fi
    if [[ -n "${DELETE_AFTER_SLEEP}" ]]; then 
        nohup sleep "${DELETE_AFTER_SLEEP}" && databricks connections delete "${CONNECTION_NAME}" >> ~/nohup.out 2>&1 &
    fi
    echo "Connection ${CONNECTION_NAME}: ${DATABRICKS_HOST}/explore/connections/${CONNECTION_NAME}"
    echo ""
else
    echo "Error: CONNECTION_ID not set"
fi
}

# #############################################################################

gw_output=$(databricks pipelines create --json '{
"name": "'"$GATEWAY_PIPELINE_NAME"'",
"gateway_definition": {
  "connection_id": "'"$CONNECTION_ID"'",
  "gateway_storage_catalog": "'"$STAGING_CATALOG"'",
  "gateway_storage_schema": "'"$STAGING_SCHEMA"'",
  "gateway_storage_name": "'"$GATEWAY_PIPELINE_NAME"'"
  }
}')
GATEWAY_PIPELINE_ID=$(echo "$gw_output" | jq -r '.pipeline_id')
export GATEWAY_PIPELINE_ID

# print UI URL
if [[ -n $GATEWAY_PIPELINE_ID ]]; then
  echo "GATEWAY_PIPELINE_ID=$GATEWAY_PIPELINE_ID"
    if [[ -n "${STOP_AFTER_SLEEP}" ]]; then 
        nohup sleep "${STOP_AFTER_SLEEP}" && databricks pipelines stop $GATEWAY_PIPELINE_ID >> ~/nohup.out 2>&1 &
    fi
    if [[ -n "${DELETE_AFTER_SLEEP}" ]]; then
        nohup sleep "${DELETE_AFTER_SLEEP}" && databricks pipelines delete $GATEWAY_PIPELINE_ID >> ~/nohup.out 2>&1 &
    fi
  echo "Gateway ${GATEWAY_PIPELINE_NAME}: ${DATABRICKS_HOST}/pipelines/$GATEWAY_PIPELINE_ID"
  echo ""
else
  echo "Error: GATEWAY_PIPELINE_NAME not set"
fi

# #############################################################################

ig_output=$(databricks pipelines create --json '{
"name": "'"$INGESTION_PIPELINE_NAME"'",
"continuous": "true",
"ingestion_definition": {
  "ingestion_gateway_id": "'"$GATEWAY_PIPELINE_ID"'",
  "objects": [
     {"schema": {
        "source_catalog": "'"$DB_CATALOG"'",
        "source_schema": "'"$DB_SCHEMA"'",
        "destination_catalog": "'"$TARGET_CATALOG"'",
        "destination_schema": "'"$TARGET_SCHEMA"'"
        }}
    ]
  }
}')
INGESTION_PIPELINE_ID=$(echo "$ig_output" | jq -r '.pipeline_id')
export INGESTION_PIPELINE_ID

ig_get_output=$(databricks pipelines get $INGESTION_PIPELINE_ID)
# print UI URL
if [[ -n $INGESTION_PIPELINE_ID ]]; then
    echo "INGESTION_PIPELINE_ID=$INGESTION_PIPELINE_ID"
    if [[ -n "${STOP_AFTER_SLEEP}" ]]; then 
        nohup sleep "${STOP_AFTER_SLEEP}" && databricks pipelines stop $INGESTION_PIPELINE_ID >> ~/nohup.out 2>&1 &
    fi
    if [[ -n "${DELETE_AFTER_SLEEP}" ]]; then
        nohup sleep "${DELETE_AFTER_SLEEP}" && databricks pipelines delete $INGESTION_PIPELINE_ID >> ~/nohup.out 2>&1 &
    fi
    if [[ $(echo "$ig_get_output" | jq -r .spec.continuous) == 'false' ]]; then databricks pipelines start-update "$INGESTION_PIPELINE_ID"; fi  
    echo "Ingestion ${INGESTION_PIPELINE_NAME}: ${DATABRICKS_HOST}/pipelines/$INGESTION_PIPELINE_ID"  
    echo ""
else
    echo "Error: INGESTION_PIPELINE_ID not set"
fi

# #############################################################################

jobs_output=$(databricks jobs create --json '{
"name":"'"$INGESTION_PIPELINE_NAME"'",
"schedule":{"timezone_id":"UTC", "quartz_cron_expression": "0 5/30 * * * ?"},
"tasks":[ {
    "task_key":"run_dlt", 
    "pipeline_task":{"pipeline_id":"'"$INGESTION_PIPELINE_ID"'"} } ]
}')

INGESTION_JOB_ID=$(echo "$jobs_output" | jq -r '.job_id')
export INGESTION_JOB_ID

# print UI URL
if [[ -n $INGESTION_JOB_ID ]]; then
    echo "INGESTION_JOB_ID=$INGESTION_JOB_ID"
    if [[ -n "${STOP_AFTER_SLEEP}" ]]; then 
        nohup sleep "${STOP_AFTER_SLEEP}" && databricks jobs delete $INGESTION_JOB_ID >> ~/nohup.out 2>&1 &
    fi
    if [[ -n "${DELETE_AFTER_SLEEP}" ]]; then
        nohup sleep "${DELETE_AFTER_SLEEP}" && databricks jobs delete $INGESTION_JOB_ID >> ~/nohup.out 2>&1 &
    fi
    if [[ $(echo "$ig_get_output" | jq -r .spec.continuous) == 'false' ]]; then databricks pipelines start-update "$INGESTION_PIPELINE_ID"; fi  
    echo "Job ${INGESTION_PIPELINE_NAME}: ${DATABRICKS_HOST}/jobs/$INGESTION_JOB_ID"   
    echo ""
else
    echo "Error: INGESTION_JOB_ID not set"
fi

# #############################################################################

jobs_pipelines_permission='{
"access_control_list": [
    {
        "user_name": "'"$DBX_USERNAME"'",
        "permission_level": "IS_OWNER"
    },
    {
        "group_name": "users",
        "permission_level": "CAN_MANAGE"
    }
]}'

databricks permissions update pipelines "$GATEWAY_PIPELINE_ID"   --json "$jobs_pipelines_permission" >/dev/null
databricks permissions update pipelines "$INGESTION_PIPELINE_ID" --json "$jobs_pipelines_permission" >/dev/null
databricks permissions update jobs       "$INGESTION_JOB_ID"     --json "$jobs_pipelines_permission" >/dev/null

# #############################################################################

cat <<EOF | sqlcmd -d "${DB_CATALOG}" -S "${DB_HOST_FQDN},${DB_PORT}" -U "${USER_USERNAME}" -P "${USER_PASSWORD}" -C -l 60 -e >/dev/null 2>&1 &
while ( 1 = 1 )
begin
insert into [${DB_SCHEMA}].[intpk] (dt) values (CURRENT_TIMESTAMP),(CURRENT_TIMESTAMP), (CURRENT_TIMESTAMP)
insert into [${DB_SCHEMA}].[dtix] (dt) values (CURRENT_TIMESTAMP),(CURRENT_TIMESTAMP),(CURRENT_TIMESTAMP)
delete from [${DB_SCHEMA}].[intpk] where pk=(select min(pk) from [${DB_SCHEMA}].[intpk])
update [${DB_SCHEMA}].[intpk] set dt=CURRENT_TIMESTAMP where pk=(select min(pk) from [${DB_SCHEMA}].[intpk])
WAITFOR DELAY '00:00:01'
end
go
EOF
LOAD_GENERATOR_PID=$!
if [[ -n "${STOP_AFTER_SLEEP}" ]]; then 
    nohup sleep "${STOP_AFTER_SLEEP}" && kill $LOAD_GENERATOR_PID >> ~/nohup.out 2>&1 &
fi
if [[ -n "${DELETE_AFTER_SLEEP}" ]]; then
    nohup sleep "${DELETE_AFTER_SLEEP}" && kill $LOAD_GENERATOR_PID >> ~/nohup.out 2>&1 &
fi
echo "Load Generator: started with PID=$LOAD_GENERATOR_PID."
echo ""