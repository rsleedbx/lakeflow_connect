#!/usr/bin/env bash

# error out when undeclared variable is used
set -u 

# grant can be done the following way
# databricks api patch /api/2.1/unity-catalog/permissions/connection/lfcddemo-mi --json "$connection_permission" 
# databricks grants update connection lfcddemo-mi --json "$connection_permission"
#  cli does not allow stdin pass

# allow all users to READ (use connection)
connection_set_all_read() {
    local DBX_PROFILE_TO=$1
    local CONNECTION_NAME=$2
    local connection_permission='{ "changes": [ { "add": [ "USE_CONNECTION" ], "principal": "account users" } ] }'
    if ! DBX --profile "$DBX_PROFILE_TO" api patch /api/2.1/unity-catalog/permissions/connection/"${CONNECTION_NAME}" --json "$connection_permission"; then
        cat /tmp/dbx_stdout.$$ /tmp/dbx_stderr.$$; return 1; 
    fi
}

# allow all users to READ
secrets_set_all_read() {
    local DBX_PROFILE_TO=$1
    local SECRETS_SCOPE=$2
    DBX --profile "$DBX_PROFILE_TO" secrets put-acl "${SECRETS_SCOPE}" users READ
}

# copy secrets from DBX_PROFILE_FROM to DBX_PROFILE_TO
secrets_copy() {
    local DBX_PROFILE_FROM=$1
    local DBX_PROFILE_TO=$2
    local SECRETS_SCOPE=$3
    local SECRETS_KEY=$4

    export DBX_PROFILE_SECRETS=$DBX_PROFILE_FROM
    if get_secrets "$SECRETS_KEY"; then
        export DBX_PROFILE_SECRETS=$DBX_PROFILE_TO
        if put_secrets "$SECRETS_KEY"; then 
            if ! DBX --profile "$DBX_PROFILE_TO" secrets list-secrets "${SECRETS_SCOPE}"; then cat /tmp/dbx_stdout.$$ /tmp/dbx_stderr.$$; return 1; fi
        fi
    fi
}

# create connections at DBX_PROFILE_TO
connection_create() {
    local DBX_PROFILE_TO=$1
    local CONNECTION_NAME=$2

    # create the connection
    local create_json='{
    "name": "'"$CONNECTION_NAME"'",
    "connection_type": "SQLSERVER",
    "options": {
            "host": "'"$DB_HOST_FQDN"'",
            "port": "'"$DB_PORT"'",
            "trustServerCertificate": "true",
            "user": "'"$USER_USERNAME"'",
            "password": "'"${USER_PASSWORD}"'"
        }
    }'
    local update_json='{
    "options": {
            "host": "'"$DB_HOST_FQDN"'",
            "port": "'"$DB_PORT"'",
            "trustServerCertificate": "true",
            "user": "'"$USER_USERNAME"'",
            "password": "'"${USER_PASSWORD}"'"
        }
    }'

    if ! DBX --profile "$DBX_PROFILE_TO" connections get "$CONNECTION_NAME"; then
        if ! DBX --profile "$DBX_PROFILE_TO" api post /api/2.1/unity-catalog/connections --json "$create_json"; then cat /tmp/dbx_stdout.$$ /tmp/dbx_stderr.$$; return 1; fi
    else 
        if ! DBX --profile "$DBX_PROFILE_TO" api patch /api/2.1/unity-catalog/connections/"${CONNECTION_NAME}" --json "$update_json" ; then cat /tmp/dbx_stdout.$$ /tmp/dbx_stderr.$$; return 1; fi
    fi
    connection_set_all_read "$DBX_PROFILE_TO" "$CONNECTION_NAME"
}

copy_secrets_connection() {
    local DBX_PROFILE_FROM="${1:-DEFAULT}"
    local DBX_PROFILE_TOS="${2:-""}"
    local SECRETS_SCOPE="${3:-lfcddemo}"
    local SECRETS_KEYS="${4:-""}"
    local DATABRICKS_CONFIG_PROFILE=""  # override DBX usage of this flag

    # set destination dbx profiles
    if [[ -z "${DBX_PROFILE_TOS[*]}" ]]; then
        if ! DBX auth profiles ; then cat /tmp/dbx_stdout.$$ /tmp/dbx_stderr.$$; return 1; fi
        read -rd "\n" -a DBX_PROFILE_TOS <<< "$(jq -r ".profiles.[] | select(.valid == true and .name != \"$DBX_PROFILE_FROM\") | .name" /tmp/dbx_stdout.$$)"
    fi
    declare -p DBX_PROFILE_TOS
    
    # set secrets keys to copy
    if [[ -z "${SECRETS_KEYS[*]}" ]]; then
        if ! DBX --profile $DBX_PROFILE_FROM secrets list-secrets $SECRETS_SCOPE; then cat /tmp/dbx_stdout.$$ /tmp/dbx_stderr.$$; return 1; fi
        read -rd "\n" -a SECRETS_KEYS <<< "$(jq -r ".[] | .key" /tmp/dbx_stdout.$$)"
    fi
    declare -p SECRETS_KEYS

    for PRTO in "${DBX_PROFILE_TOS[@]}"; do
        # copy each secret
        echo -e "\n$PRTO"
        for SK in "${SECRETS_KEYS[@]}"; do
            secrets_copy "$DBX_PROFILE_FROM" "$PRTO" "$SECRETS_SCOPE" "$SK"
            SK_SUFFIXS=(${SK//-/ })   # replace - with spaces the empty char and get the last element 
            SK_SUFFIX=${SK_SUFFIXS[-1]}

            connection_set_all_read "$DBX_PROFILE_FROM" "${SECRETS_SCOPE}-${SK_SUFFIX}"
            connection_create "$PRTO" "${SECRETS_SCOPE}-${SK_SUFFIX}"
            
        done
        # make the secret scope read all
        secrets_set_all_read "$DBX_PROFILE_FROM" "$SECRETS_SCOPE"
        secrets_set_all_read "$PRTO" "$SECRETS_SCOPE"
    
    done
}