#!/usr/bin/env bash
# Rewrite V2 secret JSON so db_type is one of: postgresql, mysql, sqlserver, oracle (lowercase).
# Fixes legacy values such as MYSQL, azure-mysql, azure-pg, oci-oracle-19c using connection_type
# and db_type heuristics (aligned with lfc_secrets_v2_db_type in 00_lakeflow_connect_env.sh).
#
# Usage:
#   ./bin/fix_v2_secret_db_type_mysql.sh <secrets_scope> <secret_key> <profile> [<profile> ...]
#
# Example:
#   ./bin/fix_v2_secret_db_type_mysql.sh lfcddemo ouveay4aeto3aiph-azure-mysql_json DEFAULT azurefe gcpfe

set -euo pipefail

if [[ $# -lt 3 ]]; then
  echo "Usage: $0 <secrets_scope> <secret_key> <databricks_profile> [<profile> ...]" >&2
  echo "  Profiles are passed as --profile (including DEFAULT). DATABRICKS_CONFIG_PROFILE is unset" >&2
  echo "  for each call so it matches explicit CLI usage." >&2
  exit 1
fi

SCOPE=$1
KEY=$2
shift 2

# Always unset DATABRICKS_CONFIG_PROFILE so an exported profile does not override --profile DEFAULT.
dbx() {
  env -u DATABRICKS_CONFIG_PROFILE databricks "$@"
}

# jq: set .db_type to canonical V2 value; error if unmappable
jq_canonical_db_type='(.connection_type // "" | ascii_upcase) as $ct |
  (.db_type // "" | ascii_downcase) as $dt |
  (
    if (["postgresql","mysql","sqlserver","oracle"] | index($dt)) != null then $dt
    elif $ct == "MYSQL" or $ct == "MARIADB" then "mysql"
    elif $ct == "POSTGRESQL" or $ct == "POSTGRES" then "postgresql"
    elif $ct == "SQLSERVER" then "sqlserver"
    elif $ct == "ORACLE" then "oracle"
    elif ($dt | test("mariadb")) or ($dt | test("mysql")) then "mysql"
    elif ($dt | test("oracle")) then "oracle"
    elif ($dt | test("postgres")) or ($dt | test("postgresql")) then "postgresql"
    elif ($dt | test("sqlserver")) or ($dt | test("sql-server")) then "sqlserver"
    elif $dt | endswith("-pg") then "postgresql"
    else empty
    end
  ) as $canon |
  if $canon == null or $canon == "" then
    error("cannot derive V2 db_type from connection_type / db_type")
  else .db_type = $canon end'

for profile in "$@"; do
  echo "== profile=$profile scope=$SCOPE key=$KEY =="
  if ! raw="$(dbx secrets get-secret "$SCOPE" "$KEY" --profile "$profile" --output json)"; then
    echo "  skip: get-secret failed (see stderr above)" >&2
    continue
  fi
  decoded="$(echo "$raw" | jq -r '.value | @base64d')"
  if ! echo "$decoded" | jq -e . >/dev/null 2>&1; then
    echo "  skip: decoded value is not JSON" >&2
    continue
  fi
  if ! fixed="$(echo "$decoded" | jq -c "$jq_canonical_db_type" 2>/dev/null)"; then
    echo "  skip: cannot map db_type to postgresql|mysql|sqlserver|oracle" >&2
    continue
  fi
  sorted_decoded="$(echo "$decoded" | jq -S -c .)"
  sorted_fixed="$(echo "$fixed" | jq -S -c .)"
  if [[ "$sorted_decoded" == "$sorted_fixed" ]]; then
    echo "  no change: already V2-compliant (db_type=$(echo "$decoded" | jq -r '.db_type'))"
    continue
  fi
  echo "  db_type: $(echo "$decoded" | jq -c '.db_type') -> $(echo "$fixed" | jq -c '.db_type')"
  dbx secrets put-secret "$SCOPE" "$KEY" --profile "$profile" --string-value "$fixed"
  echo "  updated."
done
