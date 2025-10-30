#!/usr/bin/env bash

export SECRETS_SCOPE=lfcddemo
export CONNECTION_NAME=""

# secrets to connection
declare -A sec_to_conn
sec_to_conn[choo9chu-sq_json]=lfcddemo-azure-sqlserver
sec_to_conn[eesheiphai7esuki-azure-mysql_json]=lfcddemo-azure-mysql
sec_to_conn[jouzerai9oon4moh-azure-pg_json]=lfcddemo-azure-pg
sec_to_conn[lfcddemo-vioyu9eh-ct-gt_json]=lfcddemo-gcp-sqlserver-express

# load key to last_updated_timestamp
declare -A key_last_updated_timestamp
DB_STDOUT="/tmp/dbx_secrets_list_secrets.$$" DBX secrets list-secrets $SECRETS_SCOPE
eval "$(jq -r '.[] | "key_last_updated_timestamp[\(.key|@sh)]=\(.last_updated_timestamp)"' /tmp/dbx_secrets_list_secrets.$$)"
 
# Process each JSON secret
for secrets_key in $(jq -r '
  map(.key) as $all_keys |
  .[] |
  select(.key | endswith("_json") ) |
  .key
' /tmp/dbx_secrets_list_secrets.$$); do

    CONNECTION_NAME=${sec_to_conn[$secrets_key]}
    
    echo "$secrets_key -> $CONNECTION_NAME"
    
    # Get the secret and create JSON
    DBX secrets get-secret $SECRETS_SCOPE $secrets_key

    create_json=$(jq -r '.value | @base64d' /tmp/dbx_stdout.$$ | connection_create_json_from_secrets "$CONNECTION_NAME")
    update_json=$(echo "$create_json" | jq 'del(.connection_type, .name)')
    
    # Check if connection exists and update or create
    if DBX connections get "$CONNECTION_NAME" >/dev/null 2>&1; then

        secret_timestamp=${key_last_updated_timestamp["$secrets_key"]}
        needs_update=$(jq --argjson secret_ts "$secret_timestamp" 'if ($secret_ts > (.updated_at // .created_at // 0)) then 1 else 0 end' /tmp/dbx_stdout.$$)

        if [[ "$needs_update" == "1" ]]; then
            echo "Update needed : $CONNECTION_NAME"
            DB_EXIT_ON_ERROR="PRINT_EXIT" DBX api patch "/api/2.1/unity-catalog/connections/$CONNECTION_NAME" --json "$update_json"
        else
            echo "No update needed : $CONNECTION_NAME"
        fi
    else
        echo "Creating connection: $CONNECTION_NAME"
        DB_EXIT_ON_ERROR="PRINT_EXIT" DBX connections create --json "$create_json"
    fi
done



