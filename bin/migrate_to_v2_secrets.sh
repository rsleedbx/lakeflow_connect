#!/usr/bin/env bash

SECRETS_SCOPE=lfcddemo

DB_EXIT_ON_ERROR="PRINT_EXIT" DB_STDOUT="/tmp/dbx_secrets_list.$$" DBX secrets list-secrets $SECRETS_SCOPE

# convert secrets that do not have _json equivalent
for secrets_key in $(jq -r '
  map(.key) as $all_keys |
  .[] |
  select(.key | endswith("_json") | not) |
  select((.key + "_json") as $json_key | $all_keys | index($json_key) == null) |
  .key
' /tmp/dbx_secrets_list.$$); do
    echo $secrets_key
    get_secrets $secrets_key
    DB_SCHEMA=lfcddemo
    put_secrets "${secrets_key}_json" "json" 
done