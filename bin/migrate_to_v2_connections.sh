#!/usr/bin/env bash

export SECRETS_SCOPE=lfcddemo
export CONNECTION_NAME=""

DB_EXIT_ON_ERROR="PRINT_EXIT" DB_STDOUT="/tmp/dbx_secrets_list.$$" DBX secrets list-secrets $SECRETS_SCOPE

# secrets to connection
declare -A sec_to_conn
sec_to_conn[choo9chu-sq_json]=lfcddemo-sq
sec_to_conn[eesheiphai7esuki-azure-mysql_json]=lfcddemo-azure-mysql
sec_to_conn[jouzerai9oon4moh-azure-pg_json]=lfcddemo-azure-pg
sec_to_conn[lfcddemo-vioyu9eh-ct-gt_json]=lfcddemo-gt
export sec_to_conn

# add comment to the json version
for secrets_key in $(jq -r '
  map(.key) as $all_keys |
  .[] |
  select(.key | endswith("_json") ) |
  .key
' /tmp/dbx_secrets_list.$$); do
    export CONNECTION_NAME=${sec_to_conn[$secrets_key]}
    
    echo $secrets_key $CONNECTION_NAME
    
    DBX secrets get-secret $SECRETS_SCOPE $secrets_key
    create_json=$(jq -r '.value | @base64d' /tmp/dbx_stdout.$$ | connection_create_json_from_secrets "$CONNECTION_NAME")
    update_json=$(echo "$create_json" | jq 'del(.connection_type, .name)')
    if DBX connections get $CONNECTION_NAME; then
        echo "update"
        DB_EXIT_ON_ERROR="PRINT_EXIT" DBX api patch /api/2.1/unity-catalog/connections/"$CONNECTION_NAME" --json "$update_json"
    else
        echo "create"
        DB_EXIT_ON_ERROR="PRINT_EXIT" DBX connections create --json "$create_json"
    fi
done



