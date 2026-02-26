#!/usr/bin/env bash
# List Databricks secrets, let user pick one, and (for --no-json) source it into env.
# Requires: source 00_lakeflow_connect_env.sh first; uses DBX and get_secrets from env.

set -e

# Default: show keys that do NOT end with _json (env-style secrets). Use --json to show _json keys only.
SHOW_JSON_KEYS=false
for arg in "$@"; do
  case "$arg" in
    --json)    SHOW_JSON_KEYS=true ;;
    --no-json) SHOW_JSON_KEYS=false ;;
    -h|--help) echo "Usage: ${0##*/} [--no-json|--json]"; echo "  --no-json  list non-_json keys and source selected into env (default)"; echo "  --json     list only _json keys"; exit 0 ;;
    *)         echo "Unknown option: $arg" >&2; echo "Usage: ${0##*/} [--no-json|--json]" >&2; exit 1 ;;
  esac
done

if ! declare -f get_secrets &>/dev/null || ! declare -f DBX &>/dev/null; then
  echo "Error: 00_lakeflow_connect_env.sh must be sourced first (so DBX and get_secrets are available)." >&2
  echo "  source path/to/00_lakeflow_connect_env.sh" >&2
  echo "  source bin/recreate-lost-database.sh   # or run and eval for env" >&2
  exit 1
fi

SECRETS_SCOPE="${SECRETS_SCOPE:-}"
if [[ -z "$SECRETS_SCOPE" ]]; then
  echo "Error: SECRETS_SCOPE is not set. Set it or source 00_lakeflow_connect_env.sh." >&2
  exit 1
fi

# Step 1: list secrets and filter keys
DB_EXIT_ON_ERROR="PRINT_EXIT" DBX ${DBX_PROFILE_SECRETS:+"--profile" "$DBX_PROFILE_SECRETS"} secrets list-secrets "${SECRETS_SCOPE}"
if [[ ! -s /tmp/dbx_stdout.$$ ]]; then
  echo "Error: no secrets list output." >&2
  exit 1
fi

if [[ "$SHOW_JSON_KEYS" == true ]]; then
  KEYS=()
  while IFS= read -r line; do
    [[ -n "$line" ]] && KEYS+=( "$line" )
  done < <(jq -r '.[] | select(.key | endswith("_json")) | .key' /tmp/dbx_stdout.$$)
else
  KEYS=()
  while IFS= read -r line; do
    [[ -n "$line" ]] && KEYS+=( "$line" )
  done < <(jq -r '.[] | select(.key | endswith("_json") | not) | .key' /tmp/dbx_stdout.$$)
fi

if [[ ${#KEYS[@]} -eq 0 ]]; then
  echo "No secrets found (scope=${SECRETS_SCOPE}, mode=$SHOW_JSON_KEYS)." >&2
  exit 1
fi

echo "Secrets (scope=${SECRETS_SCOPE}):"
for i in "${!KEYS[@]}"; do
  echo "  $((i+1))) ${KEYS[$i]}"
done
echo "  0) Cancel"
read -r -p "Pick number [1-${#KEYS[@]}]: " num
if [[ "$num" == "0" ]] || [[ -z "$num" ]]; then
  echo "Cancelled."
  exit 0
fi
if [[ "$num" -lt 1 ]] || [[ "$num" -gt ${#KEYS[@]} ]]; then
  echo "Invalid number." >&2
  exit 1
fi

SECRETS_KEY="${KEYS[$((num-1))]}"

# Step 2: for --no-json, source the secret into env
if [[ "$SHOW_JSON_KEYS" == false ]]; then
  if get_secrets "$SECRETS_KEY"; then
    echo "Loaded secret key: $SECRETS_KEY into current shell (DB_HOST_FQDN, DBA_USERNAME, etc.)."
    echo "To reuse in another shell, run: source 00_lakeflow_connect_env.sh && SECRETS_SCOPE=$SECRETS_SCOPE get_secrets $SECRETS_KEY"
    echo "Use SQLCMD for SQL Server, PSQL for Postgres, MYSQLCLI for MySQL."
  else
    echo "Failed to get secret: $SECRETS_KEY" >&2
    exit 1
  fi
else
  echo "Selected key (JSON): $SECRETS_KEY (not loaded as env; use get_secrets only for non-_json keys)."
fi
