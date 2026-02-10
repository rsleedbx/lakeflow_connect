#!/usr/bin/env bash

# error out when undeclared variable is used
set -u 

# don't use $1 $2 for params unless they are all required.  
# gets touch to manage with many defaults.  use local variables

# state for this script
declare -A STATE_COPY_SECRETS_CONNECTION
export STATE_COPY_SECRETS_CONNECTION

# grant can be done the following way
# databricks api patch /api/2.1/unity-catalog/permissions/connection/lfcddemo-mi --json "$connection_permission" 
# databricks grants update connection lfcddemo-mi --json "$connection_permission"
#  cli does not allow stdin pass

# copy secrets from DBX_PROFILE_FROM to DBX_PROFILE_TO
secrets_copy() {
    local -n OUTPUT="${1:-STATE_COPY_SECRETS_CONNECTION}"
    # non default values
    local DBX_PROFILE_FROM=$DBX_PROFILE_FROM
    local DBX_PROFILE_TO=$DBX_PROFILE_TO
    local SECRETS_SCOPE=$SECRETS_SCOPE
    local SECRETS_KEY=$SECRETS_KEY
    # default values
    local DRY_RUN="${DRY_RUN:-}"

    # get v1 non json
    DB_EXIT_ON_ERROR="PRINT_EXIT" DATABRICKS_CONFIG_PROFILE="$DBX_PROFILE_FROM" DBX secrets get-secret "${SECRETS_SCOPE}" "$SECRETS_KEY"
    secret_value_env="$(jq -r '.value|@base64d' /tmp/dbx_stdout.$$)"

    # get v2 json
    DB_EXIT_ON_ERROR="PRINT_EXIT" DATABRICKS_CONFIG_PROFILE="$DBX_PROFILE_FROM" DBX secrets get-secret "${SECRETS_SCOPE}" "${SECRETS_KEY}_json"
    secret_value_json="$(jq -r '.value|@base64d' /tmp/dbx_stdout.$$)"

    if [[ -z "$DRY_RUN" ]]; then
        DB_EXIT_ON_ERROR="PRINT_EXIT" DATABRICKS_CONFIG_PROFILE="$DBX_PROFILE_TO" DBX secrets  put-secret "${SECRETS_SCOPE}" "$SECRETS_KEY" --string-value "$secret_value_env"

        DB_EXIT_ON_ERROR="PRINT_EXIT" DATABRICKS_CONFIG_PROFILE="$DBX_PROFILE_TO" DBX secrets put-secret "${SECRETS_SCOPE}" "${SECRETS_KEY}_json" --string-value "$secret_value_json"
    fi

    OUTPUT[secret_value_env]="$secret_value_env"
    OUTPUT[secret_value_json]="$secret_value_json"
}

# connection name is lfcddemo-cloud-database_type
# .name .cloud.provider .db_type
connection_name_from_json() {
    local DB_NAME CLOUD_PROVIDER DB_TYPE
    # Extract all three values in one jq call
    read -r DB_NAME CLOUD_PROVIDER DB_TYPE <<< "$(jq -r '[.name, .cloud.provider, .db_type] | map(ascii_downcase) | @tsv')"
    if [[ -z "$DB_TYPE" ]]; then DB_TYPE="SQLSERVER"; fi 
    echo "$WHOAMI_USERNAME-$CLOUD_PROVIDER-$DB_TYPE"       
}

copy_secrets_connection() {
    local -n OUTPUT="${1:-STATE_COPY_SECRETS_CONNECTION}"
    # non default values
    local DRY_RUN="${DRY_RUN:-}"
    local DBX_PROFILE_FROM="${DBX_PROFILE_FROM:-DEFAULT}"
    local DBX_PROFILE_TOS="${DBX_PROFILE_TOS:-""}"
    local SECRETS_SCOPE="${SECRETS_SCOPE:-lfcddemo}"
    local SECRETS_KEYS="${SECRETS_KEYS:-""}"
    local DB_SUFFIX="${DB_SUFFIX:-azure-pg}"
    local CONNECTION_TYPE="${CONNECTION_TYPE:-SQLSERVER}"
    local DATABRICKS_CONFIG_PROFILE=""  # override DBX usage of this flag

    # set destination dbx profiles already login (.valid=true)
    echo -e "\nTarget workspaces"

    if [[ -z "${DBX_PROFILE_TOS[*]}" ]]; then
        DB_EXIT_ON_ERROR="PRINT_EXIT" DBX auth profiles
        read -rd "\n" -a DBX_PROFILE_TOS <<< "$(jq -r ".profiles.[] | select(.valid == true and .name != \"$DBX_PROFILE_FROM\") | .name" /tmp/dbx_stdout.$$)"
    fi
    declare -p DBX_PROFILE_FROM DBX_PROFILE_TOS
    
    # set secrets keys to copy (selecting v2 that ends with _json)
    echo -e "\nsecrets to copy"

    local SOURCE_SECRETS_LIST="/tmp/dbx_stdout_list_secretes_${DBX_PROFILE_FROM}_${SECRETS_SCOPE}.$$"
    if [[ -z "${SECRETS_KEYS[*]}" ]]; then
        DB_EXIT_ON_ERROR="PRINT_EXIT" DATABRICKS_CONFIG_PROFILE="$DBX_PROFILE_FROM" DB_STDOUT="$SOURCE_SECRETS_LIST" $DBX secrets list-secrets $SECRETS_SCOPE
        read -rd "\n" -a SECRETS_KEYS <<< "$(jq -r '.[] | select(.key | endswith("_json") | not) | .key' $SOURCE_SECRETS_LIST)"
    fi
    declare -p SECRETS_KEYS

    # make the from secret scope read all
    if [[ -z "$DRY_RUN" ]]; then 
        DATABRICKS_CONFIG_PROFILE="$DBX_PROFILE_FROM" SECRETS_SCOPE="$SECRETS_SCOPE" secrets_set_all_read 
    fi

    # copy the secret and create the connection
    echo -e "\nCopy secrets and create or replace connection"

    for PRTO in ${DBX_PROFILE_TOS[*]}; do
        
        # skip where from == to
        if [[ "$PRTO" == "$DBX_PROFILE_FROM" ]]; then continue; fi

        echo -e "\n$PRTO workspace"

        local TARGET_SECRETS_LIST="/tmp/dbx_stdout_list_secretes_${PRTO}_${SECRETS_SCOPE}.$$"
        DB_EXIT_ON_ERROR="PRINT_EXIT" DATABRICKS_CONFIG_PROFILE=$PRTO DB_STDOUT="$TARGET_SECRETS_LIST" DBX secrets list-secrets $SECRETS_SCOPE

        if [[ -z "$DRY_RUN" ]]; then 
            DATABRICKS_CONFIG_PROFILE="$PRTO" SECRETS_SCOPE="$SECRETS_SCOPE" secrets_set_all_read
        fi

        # copy each secret in the workspace
        for SK in "${SECRETS_KEYS[@]}"; do

            # copy secret saving secrets in secret_value_1 and secret_value_2
            echo -e "\n$PRTO workspace copy secret ${SECRETS_SCOPE} ${SK}"

            DBX_PROFILE_FROM=$DBX_PROFILE_FROM DBX_PROFILE_TO=$PRTO SECRETS_SCOPE=$SECRETS_SCOPE SECRETS_KEY=$SK secrets_copy 

            # create connection in the target
            local CONNECTION_NAME=$( echo "${OUTPUT[secret_value_json]}" | connection_name_from_json)

            echo -e "\n$PRTO workspace create connection $CONNECTION_NAME"
    
            if [[ -z "$DRY_RUN" ]]; then 
                CONNECTION_NAME="$CONNECTION_NAME" SECRETS_SCOPE="$SECRETS_SCOPE" connection_spec_from_json STATE_COPY_SECRETS_CONNECTION

                DATABRICKS_CONFIG_PROFILE="${PRTO}" connection_create_or_replace STATE_COPY_SECRETS_CONNECTION
            fi
        done
    done
}