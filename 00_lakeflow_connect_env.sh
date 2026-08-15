#!/usr/bin/env bash

# error out when undeclared variable is used
set -u

# must be sourced for exports to continue to the next script
if [ "$0" == "$BASH_SOURCE" ]; then
  echo "Script is being executed directly. Please run as source $0"
  exit 1
fi

if [ -z "$BASH_VERSINFO" ]; then
    echo "BASH_VERSION not defined"
    kill -INT $$
fi

if (( ${BASH_VERSINFO[0]} < 4 )); then
    echo "bash 4.0 or greater needed. $BASH_VERSION found. Run the following:"
    echo ""
    echo "brew install bash                     # install bash"
    echo "/opt/homebrew/bin/bash                # start bash"
    echo "export PATH=/opt/homebrew/bin:$PATH   # set PATH"
    echo ""
    echo "run the command again"
    kill -INT $$
fi

_LFC_REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export _LFC_REPO_ROOT
# shellcheck source=bash_utils/cmd-wrapper-helpers.sh
source "${_LFC_REPO_ROOT}/bash_utils/cmd-wrapper-helpers.sh"

# config 
declare -A CONFIG 
export CONFIG

# state
declare -A STATE 
export STATE

# frequently setup settings
echo "First is the default
DATABRICKS_CONFIG_PROFILE=dogfoodazure|dogfoodaws
CDC_QBC=cdc|icdc|cdc_single_pipeline|qbc_fcon|qbc_fc
GATEWAY_COMPUTE=default|serverless|classic
INGEST_COMPUTE=default|serverless|classic
"

if ! declare -p DATABRICKS_CONFIG_PROFILE &> /dev/null; then
    DATABRICKS_CONFIG_PROFILE=dogfoodazure
fi

# set tags that will resources remove using cloud scheduler
if ! declare -p REMOVE_AFTER &> /dev/null; then
    if ! REMOVE_AFTER=$(date --date='+0 day' +%Y-%m-%d 2>/dev/null); then   # blank is do not delete
        if ! REMOVE_AFTER=$(date -v '+0d' +%Y-%m-%d 2>/dev/null); then      # bsd style
            echo "could not set the date"
            kill -INT $$
        fi
    fi
    export REMOVE_AFTER
fi

if ! declare -p PUBLISH_EVENT_LOG &> /dev/null; then
export PUBLISH_EVENT_LOG=${PUBLISH_EVENT_LOG:-""}            # don't publish (not supported yet ) 
fi

if ! declare -p GATEWAY_DRIVER_NODE &> /dev/null; then
export GATEWAY_DRIVER_NODE=${GATEWAY_DRIVER_NODE:-""}       # m5.xlarge (4 cores), m5.2xlarge (8cores), m-fleet.large, m-fleet.xlarge, m-fleet.2xlarge 
fi

if ! declare -p GATEWAY_WORKER_NODE &> /dev/null; then
export GATEWAY_WORKER_NODE=${GATEWAY_WORKER_NODE:-""}       # m5.xlarge (4 cores), m5.2xlarge (8cores)
fi

if ! declare -p GATEWAY_MIN_WORKERS &> /dev/null; then
export GATEWAY_MIN_WORKERS=${GATEWAY_MIN_WORKERS:-""}       # 1 = default 
fi

if ! declare -p GATEWAY_DRIVER_POOL &> /dev/null; then
export GATEWAY_MAX_WORKERS=${GATEWAY_MAX_WORKERS:-""}       # 5 = default
fi

if ! declare -p GATEWAY_DRIVER_POOL &> /dev/null; then
export GATEWAY_DRIVER_POOL=${GATEWAY_DRIVER_POOL:-""}        
fi

if ! declare -p GATEWAY_WORKER_POOL &> /dev/null; then
export GATEWAY_WORKER_POOL=${GATEWAY_WORKER_POOL:-""}       
fi

export GATEWAY_PIPELINE_CONTINUOUS=${GATEWAY_PIPELINE_CONTINUOUS:-"true"}   # cannot be false

if ! declare -p DML_INTERVAL_SEC &> /dev/null; then
export DML_INTERVAL_SEC=${DML_INTERVAL_SEC:-01}             # >= 0, 0=no DML
fi

if ! declare -p PIPELINE_DEV_MODE &> /dev/null; then
export PIPELINE_DEV_MODE=${PIPELINE_DEV_MODE:-"false"}          # true | false
fi

if ! declare -p INITIAL_SNAPSHOT_ROWS &> /dev/null; then
export INITIAL_SNAPSHOT_ROWS=${INITIAL_SNAPSHOT_ROWS:-"1"}      # >= 0, 0=no initial data
fi

if ! declare -p JOBS_PERFORMANCE_MODE &> /dev/null; then
export JOBS_PERFORMANCE_MODE=${JOBS_PERFORMANCE_MODE:-"STANDARD"}      # PERFORMANCE_OPTIMIZED | STANDARD
fi

# stop after sleep
if ! declare -p STOP_AFTER_SLEEP &> /dev/null; then
export STOP_AFTER_SLEEP=${STOP_AFTER_SLEEP:-"480m"}      # blank is do not stop
fi

# delete database after sleep
if ! declare -p DELETE_DB_AFTER_SLEEP &> /dev/null; then
export DELETE_DB_AFTER_SLEEP=${DELETE_DB_AFTER_SLEEP:-"480m"}    # blank is do not delete
fi

# delete lakeflow objects after sleep 
if ! declare -p DELETE_PIPELINES_AFTER_SLEEP &> /dev/null; then
export DELETE_PIPELINES_AFTER_SLEEP=${DELETE_PIPELINES_AFTER_SLEEP:-"120m"}  # blank is do not delete
fi

# save credentials in secrets so that password reset won't be required
if ! declare -p GET_DBX_SECRETS &> /dev/null; then
export GET_DBX_SECRETS=1
fi
if ! declare -p PUT_DBX_SECRETS &> /dev/null; then
export PUT_DBX_SECRETS=1
fi

# databricks options
# used to recover from invalid secrets load
declare -A vars_before_secrets
export vars_before_secrets
export SECRETS_RETRIEVED=0  # indicate secrets was successfully retrieved
export DBX_PROFILE=${DBX_PROFILE:-"DEFAULT"}
export DBX_PROFILE_SECRETS=${DBX_PROFILE_SECRETS:-"DEFAULT"}

# permissive firewall by default.  DO NOT USE WITH PRODUCTION SCHEMA or DATA
export DB_FIREWALL_CIDRS="${DB_FIREWALL_CIDRS:-"0.0.0.0/0"}"
export CLOUD_LOCATION="${CLOUD_LOCATION:-"East US"}"

# Azure options
export AZ_DB_TYPE=${AZ_DB_TYPE:-""}         # zmi|zsql
export az_tenantDefaultDomain=${az_tenantDefaultDomain:-""}
export az_id=${az_id:-""}
export az_user_name=${az_user_name:-""}

# used everywhere
export DB_HOST=${DB_HOST:-""}
export DB_HOST_FQDN=${DB_HOST_FQDN:-""}
export DB_CATALOG=${DB_CATALOG:-""}
export DBX_USERNAME=${DBX_USERNAME:-""}
export DBA_PASSWORD=${DBA_PASSWORD:-""}
export USER_PASSWORD=${USER_PASSWORD:-""}

# gateway pipeline options
export CONNECTION_NAME="${CONNECTION_NAME:-""}"
export CDC_CT_MODE=${CDC_CT_MODE:-"BOTH"}   # ['BOTH'|'CT'|'CDC'|'NONE']

# pipeline architecture: cdc (gw+ingest) | qbc_fcon (query-based foreign connection) | qbc_fc (query-based foreign catalog) | cdc_single_pipeline|icdc (integrated CDC, no separate gateway)
export CDC_QBC=${CDC_QBC:-"cdc"}
# compute per pipeline: default (let DBX decide) | classic | serverless
export COMPUTE_GATEWAY=${COMPUTE_GATEWAY:-"default"}
export COMPUTE_INGEST=${COMPUTE_INGEST:-"default"}

# Postgres: when 1, 03 creates a per-pipeline slot/pub (NINE_CHAR_ID) and passes slot_config.
# 02 does not create a shared default slot/pub. Set 0 to omit slot_config (Databricks owns lifecycle).
case "${PG_PRECREATE_SLOT_PUB:-1}" in
  1|true|TRUE|yes|YES|y|Y) export PG_PRECREATE_SLOT_PUB="1" ;;
  0|false|FALSE|no|NO|n|N) export PG_PRECREATE_SLOT_PUB="0" ;;
  *)
    echo "PG_PRECREATE_SLOT_PUB=${PG_PRECREATE_SLOT_PUB} must be 1/true or 0/false; defaulting to 1" >&2
    export PG_PRECREATE_SLOT_PUB="1"
    ;;
esac

# ingestion pipeline options
export SCD_TYPE=${SCD_TYPE:-""} # SCD_TYPE_1 | SCD_TYPE_2
export INGESTION_PIPELINE_CONTINUOUS=${INGESTION_PIPELINE_CONTINUOUS:-false}
export INGESTION_PIPELINE_MIN_TRIGGER=${INGESTION_PIPELINE_MIN_TRIGGER:-5}

if [[ "$INGESTION_PIPELINE_CONTINUOUS" != "false" ]]; then
    INGESTION_PIPELINE_MIN_TRIGGER=0
fi

# call using 
# RC="$RC" DB_EXIT_ON_ERROR="$DB_EXIT_ON_ERROR" DB_STDOUT="$DB_STDOUT" DB_STDERR="$DB_STDERR" CONT_OR_EXIT
CONT_OR_EXIT() {
    if [[ "$RC" != "0" ]]; then
        if [[ "PRINT_RETURN" == "$DB_EXIT_ON_ERROR" ]]; then
            echo " failed with $RC"; cat "${DB_STDOUT}" "${DB_STDERR}"
            return $RC
        elif [[ "PRINT_EXIT" == "$DB_EXIT_ON_ERROR" ]]; then 
            echo " failed with ${RC}."; cat "${DB_STDOUT}" "${DB_STDERR}"
            kill -INT $$
        else
            echo " failed with ${RC}. This is ok and continuing.";
            return $RC
        fi
    elif [[ "$RC" == "0" ]]; then
        echo "" 
        if [[ "RETURN_1_STDOUT_EMPTY" == "$DB_EXIT_ON_ERROR" && ! -s "${DB_STDOUT}" ]]; then 
                return 1
        fi
        return 0
    fi
}
export -f CONT_OR_EXIT

# Map legacy DB_* prefix vars to CMD_* (for scripts not yet migrated to CMD directly).
cmd_sync_db_vars() {
    CMD_EXIT_ON_ERROR="${DB_EXIT_ON_ERROR:-${CMD_EXIT_ON_ERROR:-}}"
    CMD_OUT_SUFFIX="${DB_OUT_SUFFIX:-${CMD_OUT_SUFFIX:-}}"
    CMD_STDOUT="${DB_STDOUT:-${CMD_STDOUT:-}}"
    CMD_STDERR="${DB_STDERR:-${CMD_STDERR:-}}"
}

# Azure secret masking for CMD_MASK_SECRETS (set as standalone statement before CMD).
cmd_mask_azure_secrets() {
    CMD_MASK_SECRETS=()
    [[ -n "${DBA_PASSWORD:-}" ]] && CMD_MASK_SECRETS+=("$DBA_PASSWORD")
    [[ -n "${USER_PASSWORD:-}" ]] && CMD_MASK_SECRETS+=("$USER_PASSWORD")
    [[ -n "${az_tenantDefaultDomain:-}" ]] && CMD_MASK_SECRETS+=("$az_tenantDefaultDomain")
    [[ -n "${az_id:-}" ]] && CMD_MASK_SECRETS+=("$az_id")
    [[ -n "${az_user_name:-}" ]] && CMD_MASK_SECRETS+=("$az_user_name")
}
export -f cmd_sync_db_vars cmd_mask_azure_secrets

# display AZ commands (thin wrapper over CMD for scripts not yet migrated)
AZ() {
    cmd_sync_db_vars
    cmd_mask_azure_secrets
    CMD az "$@"
}
export -f AZ

# display AWS commands
AWS() {
    local DB_EXIT_ON_ERROR=${DB_EXIT_ON_ERROR:-""}
    # stdout and stderr file names
    local DB_OUT_SUFFIX=${DB_OUT_SUFFIX:-""}
    local DB_STDOUT=${DB_STDOUT:-"/tmp/aws_stdout${DB_OUT_SUFFIX:+_${DB_OUT_SUFFIX}}.$$"}
    local DB_STDERR=${DB_STDERR:-"/tmp/aws_stderr${DB_OUT_SUFFIX:+_${DB_OUT_SUFFIX}}.$$"}
    local RC

    PWMASK="$@"
    PWMASK="${PWMASK//$DBA_PASSWORD/\$DBA_PASSWORD}"
    PWMASK="${PWMASK//$USER_PASSWORD/\$USER_PASSWORD}"
    echo -n aws "${PWMASK}" --no-cli-pager ${AWS_CONFIG_PROFILE:+--profile $AWS_CONFIG_PROFILE}
    aws "$@" --no-cli-pager ${AWS_CONFIG_PROFILE:+--profile $AWS_CONFIG_PROFILE} >${DB_STDOUT} 2>${DB_STDERR}

    RC=$?
    RC="$RC" DB_EXIT_ON_ERROR="$DB_EXIT_ON_ERROR" DB_STDOUT="$DB_STDOUT" DB_STDERR="$DB_STDERR" CONT_OR_EXIT
    return $?
}
export -f AWS

AWS_INIT() {
    echo -e "aws init"
    echo -e "-------\n"

    if ! DB_EXIT_ON_ERROR="PRINT_RETURN" AWS sts get-caller-identity; then 
        
        echo "Run aws configure sso the first time to setup .aws/config"
        echo "add [default] to .aws/config or export AWS_CONFIG_PROFILE=profile name"
        echo "Run aws sso login after that to login again"
        kill -INT $$
    fi
}
export -f AWS_INIT

AZ_INIT() {

    echo -e "az init"
    echo -e "-------\n"

    CMD_EXIT_ON_ERROR=PRINT_EXIT
    cmd_mask_azure_secrets
    CMD az account show
    export az_id="${az_id:-$(jq -r '.id' /tmp/az_stdout.$$)}" 
    export az_tenantDefaultDomain="${az_tenantDefaultDomain:-$(jq -r '.tenantDefaultDomain' /tmp/az_stdout.$$)}"
    export az_user_name="${az_user_name:-$(jq -r '.user.name' /tmp/az_stdout.$$)}"

    # set default location
    if [[ -n "${CLOUD_LOCATION}" ]]; then 
        CMD_EXIT_ON_ERROR=PRINT_EXIT
        cmd_mask_azure_secrets
        CMD az configure ${CLOUD_LOCATION:+--defaults location="${CLOUD_LOCATION}"}
    fi

    # create resource group
    cmd_mask_azure_secrets
    CMD_EXIT_ON_ERROR=
    if ! CMD az group show --resource-group "${RG_NAME}"; then
        # multiples tags are defined correctly below.  NOT A MISTAKE
        CMD_EXIT_ON_ERROR=PRINT_EXIT
        cmd_mask_azure_secrets
        CMD az group create --resource-group "${RG_NAME}" \
            --tags "Owner=${DBX_USERNAME}" "${REMOVE_AFTER:+RemoveAfter=${REMOVE_AFTER}}"
    fi

    # set default resource group
    RG_NAME=$(jq -r .name /tmp/az_stdout.$$)
    CMD_EXIT_ON_ERROR=PRINT_EXIT
    cmd_mask_azure_secrets
    CMD az configure --defaults group="${RG_NAME}"    

    # show billing for the resource group
    echo -e "\nBilling for ${RG_NAME}: https://portal.azure.com/#@${az_tenantDefaultDomain}/resource/subscriptions/${az_id}/resourceGroups/${RG_NAME}/costanalysis"
}
export -f AZ_INIT

GCLOUD_INIT() {

    echo -e "gcloud init"
    echo -e "-----------\n"

    DB_EXIT_ON_ERROR="PRINT_EXIT" GCLOUD config list
    export GCLOUD_PROJECT="$(jq -r ".core.project" /tmp/gcloud_stdout.$$)"
    export GCLOUD_REGION="$(jq -r ".compute.region" /tmp/gcloud_stdout.$$)"
    export GCLOUD_ZONE="$(jq -r ".compute.zone" /tmp/gcloud_stdout.$$)"
}

# display GLCOUD commands
GCLOUD() {
    local DB_EXIT_ON_ERROR=${DB_EXIT_ON_ERROR:-""}
    # stdout and stderr file names
    local DB_OUT_SUFFIX=${DB_OUT_SUFFIX:-""}
    local DB_STDOUT=${DB_STDOUT:-"/tmp/gcloud_stdout${DB_OUT_SUFFIX:+_${DB_OUT_SUFFIX}}.$$"}
    local DB_STDERR=${DB_STDERR:-"/tmp/gcloud_stderr${DB_OUT_SUFFIX:+_${DB_OUT_SUFFIX}}.$$"}
    local RC

    PWMASK="$@"
    PWMASK="${PWMASK//$DBA_PASSWORD/\$DBA_PASSWORD}"
    PWMASK="${PWMASK//$USER_PASSWORD/\$USER_PASSWORD}"
    echo -n gcloud "${PWMASK}" --quiet --format=json
    gcloud "$@" --quiet --format=json >${DB_STDOUT} 2>${DB_STDERR}

    RC=$?
    RC="$RC" DB_EXIT_ON_ERROR="$DB_EXIT_ON_ERROR" DB_STDOUT="$DB_STDOUT" DB_STDERR="$DB_STDERR" CONT_OR_EXIT
    return $?
}
export -f GCLOUD


OCI_INIT() {

    echo -e "oci setup config"
    echo -e "-------\n"

}
export -f OCI_INIT

# display OCI commands
OCI() {
    local DB_EXIT_ON_ERROR=${DB_EXIT_ON_ERROR:-""}
    # stdout and stderr file names
    local DB_OUT_SUFFIX=${DB_OUT_SUFFIX:-""}
    local DB_STDOUT=${DB_STDOUT:-"/tmp/oci_stdout${DB_OUT_SUFFIX:+_${DB_OUT_SUFFIX}}.$$"}
    local DB_STDERR=${DB_STDERR:-"/tmp/oci_stderr${DB_OUT_SUFFIX:+_${DB_OUT_SUFFIX}}.$$"}
    local RC

    PWMASK="$@"
    PWMASK="${PWMASK//$DBA_PASSWORD/\$DBA_PASSWORD}"
    PWMASK="${PWMASK//$USER_PASSWORD/\$USER_PASSWORD}"
    echo -n oci "${PWMASK}"
    oci "$@" >${DB_STDOUT} 2>${DB_STDERR}

    RC=$?
    RC="$RC" DB_EXIT_ON_ERROR="$DB_EXIT_ON_ERROR" DB_STDOUT="$DB_STDOUT" DB_STDERR="$DB_STDERR" CONT_OR_EXIT
    return $?
}
export -f OCI

DBX() {
    local DB_EXIT_ON_ERROR=${DB_EXIT_ON_ERROR:-""}
    # stdout and stderr file names
    local DB_OUT_SUFFIX=${DB_OUT_SUFFIX:-""}
    local DB_STDOUT=${DB_STDOUT:-"/tmp/dbx_stdout${DB_OUT_SUFFIX:+_${DB_OUT_SUFFIX}}.$$"}
    local DB_STDERR=${DB_STDERR:-"/tmp/dbx_stderr${DB_OUT_SUFFIX:+_${DB_OUT_SUFFIX}}.$$"}
    local RC

    PWMASK="$@"
    PWMASK="${PWMASK//$DBA_PASSWORD/\$DBA_PASSWORD}"
    PWMASK="${PWMASK//$USER_PASSWORD/\$USER_PASSWORD}"
    PWMASK="${PWMASK//$DBX_USERNAME/\$DBX_USERNAME}"

    echo -n "databricks ${PWMASK} ${DATABRICKS_CONFIG_PROFILE:+--profile $DATABRICKS_CONFIG_PROFILE}"
    databricks "${@}" --output json ${DATABRICKS_CONFIG_PROFILE:+--profile $DATABRICKS_CONFIG_PROFILE} >${DB_STDOUT} 2>${DB_STDERR}

    RC=$?
    RC="$RC" DB_EXIT_ON_ERROR="$DB_EXIT_ON_ERROR" DB_STDOUT="$DB_STDOUT" DB_STDERR="$DB_STDERR" CONT_OR_EXIT
    return $?
}
export -f DBX

SQLCMD() {
    local DB_USERNAME=${DB_USERNAME:-${USER_USERNAME}}
    local DB_PASSWORD=${DB_PASSWORD:-${USER_PASSWORD}}
    local DB_HOST_FQDN=${DB_HOST_FQDN}
    local DB_PORT=${DB_PORT:-${1433}}
    local DB_CATALOG=${DB_CATALOG:-"master"}
    local DB_LOGIN_TIMEOUT=${DB_LOGIN_TIMEOUT:-10}
    local DB_URL=${DB_URL:-""}
    local DB_EXIT_ON_ERROR=${DB_EXIT_ON_ERROR:-""}
    # stdout and stderr file names
    local DB_OUT_SUFFIX=${DB_OUT_SUFFIX:-""}
    local DB_STDOUT=${DB_STDOUT:-"/tmp/sqlcmd_stdout${DB_OUT_SUFFIX:+_${DB_OUT_SUFFIX}}.$$"}
    local DB_STDERR=${DB_STDERR:-"/tmp/sqlcmd_stderr${DB_OUT_SUFFIX:+_${DB_OUT_SUFFIX}}.$$"}

    PWMASK="sqlcmd -d '$DB_CATALOG' -S '${DB_HOST_FQDN},${DB_PORT}' -U '${DB_USERNAME}' -P '${DB_PASSWORD}' -C -l '${DB_LOGIN_TIMEOUT}' -h -1 ${*}"
    PWMASK="${PWMASK//$DBA_PASSWORD/\$DBA_PASSWORD}"
    PWMASK="${PWMASK//$USER_PASSWORD/\$USER_PASSWORD}"
    PWMASK="${PWMASK//$DBX_USERNAME/\$DBX_USERNAME}"

    echo "${PWMASK}"

    if [[ -t 0 ]]; then
        # stdin is attached
        sqlcmd -d "$DB_CATALOG" -S "${DB_HOST_FQDN},${DB_PORT}" -U "${DB_USERNAME}" -P "${DB_PASSWORD}" -C -l "${DB_LOGIN_TIMEOUT}" "${@}"
    else
        # running in batch mode
        sqlcmd -d "$DB_CATALOG" -S "${DB_HOST_FQDN},${DB_PORT}" -U "${DB_USERNAME}" -P "${DB_PASSWORD}" -C -l "${DB_LOGIN_TIMEOUT}" -h -1 "${@}" >${DB_STDOUT} 2>${DB_STDERR} 
    fi

    RC=$?
    RC="$RC" DB_EXIT_ON_ERROR="$DB_EXIT_ON_ERROR" DB_STDOUT="$DB_STDOUT" DB_STDERR="$DB_STDERR" CONT_OR_EXIT
    return $?
}
export -f SQLCMD

# Helper to run SQL as DBA user
SQLCMD_DBA() {
    DB_USERNAME="${DBA_USERNAME}" DB_PASSWORD="${DBA_PASSWORD}" SQLCMD "${@}"
}
export -f SQLCMD_DBA

PSQL() {
    local DB_USERNAME=${DB_USERNAME:-${USER_USERNAME}}
    local DB_PASSWORD=${DB_PASSWORD:-${USER_PASSWORD}}
    local DB_HOST_FQDN=${DB_HOST_FQDN}
    local DB_PORT=${DB_PORT:-${5432}}
    local DB_CATALOG=${DB_CATALOG:-"postgres"}
    local DB_LOGIN_TIMEOUT=${DB_LOGIN_TIMEOUT:-10}
    local DB_SSLMODE=${DB_SSLMODE:-"allow"}
    local DB_URL=${DB_URL:-""}
    local DB_EXIT_ON_ERROR=${DB_EXIT_ON_ERROR:-""}
    # stdout and stderr file names
    local DB_OUT_SUFFIX=${DB_OUT_SUFFIX:-""}
    local DB_STDOUT=${DB_STDOUT:-"/tmp/psql_stdout${DB_OUT_SUFFIX:+_${DB_OUT_SUFFIX}}.$$"}
    local DB_STDERR=${DB_STDERR:-"/tmp/psql_stderr${DB_OUT_SUFFIX:+_${DB_OUT_SUFFIX}}.$$"}
    local DB_URL=${DB_URL:-"postgresql://${DB_USERNAME}@${DB_HOST_FQDN}:${DB_PORT}/${DB_CATALOG}?sslmode=${DB_SSLMODE}"}

    PWMASK="${*}"
    PWMASK="${PWMASK//$DBA_PASSWORD/\$DBA_PASSWORD}"
    PWMASK="${PWMASK//$USER_PASSWORD/\$USER_PASSWORD}"
    PWMASK="${PWMASK//$DBX_USERNAME/\$DBX_USERNAME}"
    PWMASK="${PWMASK//$DBA_USERNAME/\$DBA_USERNAME}"
    PWMASK="${PWMASK//$USER_USERNAME/\$USER_USERNAME}"

    if [[ $DB_PASSWORD == $DBA_PASSWORD ]]; then
        echo "PGPASSWORD=\$DBA_PASSWORD psql ${DB_URL} ${PWMASK}" 
    elif [[ $DB_PASSWORD == $USER_PASSWORD ]]; then
        echo "PGPASSWORD=\$USER_PASSWORD psql ${DB_URL} ${PWMASK}" 
    else
        echo "psql ${DB_URL} -W ${PWMASK}"     
    fi

    export PGPASSWORD=$DB_PASSWORD
    export PGCONNECT_TIMEOUT=$DB_LOGIN_TIMEOUT
    if [[ -t 0 ]]; then
        # stdin is attached
        psql "${DB_URL}" "${@}" 
    else
        # running in batch mode
        psql "${DB_URL}" -q --csv --tuples-only "${@}" >${DB_STDOUT} 2>${DB_STDERR} 
    fi

    RC=$?
    RC="$RC" DB_EXIT_ON_ERROR="$DB_EXIT_ON_ERROR" DB_STDOUT="$DB_STDOUT" DB_STDERR="$DB_STDERR" CONT_OR_EXIT
    return $?
}
export -f PSQL
 
MYSQLCLI() {
    local DB_USERNAME=${DB_USERNAME:-${USER_USERNAME}}
    local DB_PASSWORD=${DB_PASSWORD:-${USER_PASSWORD}}
    local DB_HOST_FQDN=${DB_HOST_FQDN}
    local DB_PORT=${DB_PORT:-${1433}}
    local DB_CATALOG=${DB_CATALOG:-"mysql"}
    local DB_LOGIN_TIMEOUT=${DB_LOGIN_TIMEOUT:-10}
    local DB_SSLMODE=${DB_SSLMODE:-"allow"}
    local DB_URL=${DB_URL:-""}
    local DB_EXIT_ON_ERROR=${DB_EXIT_ON_ERROR:-""}
    # stdout and stderr file names
    local DB_OUT_SUFFIX=${DB_OUT_SUFFIX:-""}
    local DB_STDOUT=${DB_STDOUT:-"/tmp/mysql_stdout${DB_OUT_SUFFIX:+_${DB_OUT_SUFFIX}}.$$"}
    local DB_STDERR=${DB_STDERR:-"/tmp/mysql_stderr${DB_OUT_SUFFIX:+_${DB_OUT_SUFFIX}}.$$"}
    local DB_URL
    if [[ -z $DB_URL ]]; then
        DB_URL="--user ${DB_USERNAME} --host ${DB_HOST_FQDN} --port ${DB_PORT} --database ${DB_CATALOG}"
    fi

    PWMASK="${*}"
    PWMASK="${PWMASK//$DBA_PASSWORD/\$DBA_PASSWORD}"
    PWMASK="${PWMASK//$USER_PASSWORD/\$USER_PASSWORD}"

    if [[ $DB_PASSWORD == $DBA_PASSWORD ]]; then
        echo "MYSQL_PWD=\$DBA_PASSWORD mysql ${DB_URL} ${PWMASK}" 
    elif [[ $DB_PASSWORD == $USER_PASSWORD ]]; then
        echo "MYSQL_PWD=\$USER_PASSWORD mysql ${DB_URL} ${PWMASK}" 
    else
        echo "mysql ${DB_URL} ${PWMASK}"     
    fi

    export MYSQL_PWD=$DB_PASSWORD
    if [[ -t 0 ]]; then
        # stdin is attached
        mysql ${DB_URL} "${@}" 
    else
        # running in batch mode
        mysql ${DB_URL} --batch --skip-column-names --silent "${@}" >${DB_STDOUT} 2>${DB_STDERR} 
    fi

    RC=$?
    RC="$RC" DB_EXIT_ON_ERROR="$DB_EXIT_ON_ERROR" DB_STDOUT="$DB_STDOUT" DB_STDERR="$DB_STDERR" CONT_OR_EXIT
    return $?
}
export -f MYSQLCLI


export WHOAMI_USERNAME=${WHOAMI_USERNAME:-$(whoami)}
export WHOAMI="$(echo "$WHOAMI_USERNAME" | tr -d '\-\.\_')"

# Fail early if the effective Databricks CLI profile is missing from ~/.databrickscfg.
# Without this, DBX/auth falls through to DEFAULT and fails with a cryptic resolve error.
ensure_databricks_profile() {
    local cfg="${DATABRICKS_CONFIG_FILE:-$HOME/.databrickscfg}"
    local effective=""
    local profiles=""
    local p=""

    if [[ -n "${DATABRICKS_CONFIG_PROFILE:-}" ]]; then
        effective="${DATABRICKS_CONFIG_PROFILE}"
    elif [[ -n "${DBX_PROFILE:-}" ]]; then
        effective="${DBX_PROFILE}"
    else
        effective="DEFAULT"
    fi

    if [[ ! -f "$cfg" ]]; then
        echo "ERROR: Databricks config not found: $cfg" >&2
        echo "Fix: run 'databricks auth login --profile <name>' or export DATABRICKS_CONFIG_PROFILE=<name>" >&2
        kill -INT $$
    fi

    if ! grep -Fxq "[${effective}]" "$cfg"; then
        echo "ERROR: Databricks profile '${effective}' not found in ${cfg}" >&2
        echo "Available profiles:" >&2
        while IFS= read -r p; do
            [[ -z "$p" || "$p" == "__settings__" ]] && continue
            echo "  $p" >&2
        done < <(grep -E '^\[' "$cfg" | tr -d '[]')
        echo "Fix: export DATABRICKS_CONFIG_PROFILE=<name>   # e.g. e2dogfood" >&2
        kill -INT $$
    fi

    export DATABRICKS_CONFIG_PROFILE="$effective"
    export DBX_PROFILE="$effective"
}
export -f ensure_databricks_profile
ensure_databricks_profile

if [[ -z "$DBX_USERNAME" ]]; then
    DB_EXIT_ON_ERROR="PRINT_EXIT" DBX current-user me
    DBX_USERNAME="$(jq -r .userName /tmp/dbx_stdout.$$)"
fi
export DBX_USERNAME
export DBX_USERNAME_NO_DOMAIN="${DBX_USERNAME%%@*}"                  # remove everything after the first @
export DBX_USERNAME_NO_DOMAIN_DOT="${DBX_USERNAME_NO_DOMAIN//./_}"   # . to _

export RG_NAME=${RG_NAME:-${WHOAMI}-rg}                # resource group name
export DBX_WORKSPACE_PATH=${DBX_WORKSPACE_PATH:-"/Users/${DBX_USERNAME}/lfcddemokit"}

# Workspace default Unity Catalog catalog (settings default-namespace).
# Safe for command substitution: DBX command-echo goes to stderr.
resolve_default_uc_catalog() {
    DB_EXIT_ON_ERROR="PRINT_EXIT" DBX settings default-namespace get 1>&2
    local cat
    cat="$(jq -r '.namespace.value // empty' /tmp/dbx_stdout.$$)"
    if [[ -z "$cat" || "$cat" == "null" ]]; then
        echo "ERROR: could not resolve default UC catalog from settings default-namespace" >&2
        kill -INT $$
    fi
    printf '%s' "$cat"
}
export -f resolve_default_uc_catalog

# return 3 variables
read_fqdn_dba_if_host(){
    # assume list
    local x1=""
    local x2=""
    local x3=""
    read -rd "\n" x1 <<< "$(jq -r 'first(.[]) | .name' /tmp/az_stdout.$$ 2>/dev/null)" 
    # assume not a list
    if [[ -n "${x1}" ]]; then
        read -rd "\n" x2 x3 <<< "$(jq -r 'first(.[] | select(.fullyQualifiedDomainName!=null)) | .fullyQualifiedDomainName, .administratorLogin' /tmp/az_stdout.$$)"
    else
        read -rd "\n" x1 <<< "$(jq -r '.name' /tmp/az_stdout.$$ 2>/dev/null)"
        if [[ -n "${x1}" ]]; then
            read -rd "\n" x2 x3 <<< "$(jq -r '.fullyQualifiedDomainName, .administratorLogin' /tmp/az_stdout.$$)"
        fi
    fi
    if [[ -n $x1 && -n $x2 && -n $x3 ]]; then DB_HOST="$x1"; DB_HOST_FQDN="$x2"; DBA_USERNAME="$x3"; fi
}

# return 1 variable
set_mi_fqdn_dba_host() {
    DB_HOST_FQDN="${DB_HOST_FQDN/${DB_HOST}./${DB_HOST}.public.}"
}

# used when creating.  preexisting db admin will be used
export DBA_USERNAME=${DBA_USERNAME:-$(pwgen -1AB 16)}        # GCP hardcoded to defaults to sqlserver.  Make it same for Azure
export USER_USERNAME=${USER_USERNAME:-$(pwgen -1AB 16)}      # set if not defined
export DBA_BASENAME=${DBA_USERNAME}      # set if not defined
export USER_BASENAME=${USER_USERNAME}      # set if not defined

# DB and catalog basename
export DB_BASENAME=${DB_BASENAME:-$(pwgen -1AB 16)}        # lower case, name seen on internet
export CATALOG_BASENAME=${CATALOG_BASENAME:-$(pwgen -1AB 8)}

# special char mess up eval and bash string substitution
export DBA_PASSWORD="${DBA_PASSWORD:-$(pwgen -1y   -r \-\[\]\{\}\!\=\~\^\$\;\(\)\:\.\*\@\\\/\<\>\`\"\'\| 32 )}"  # set if not defined
export USER_PASSWORD="${USER_PASSWORD:-$(pwgen -1y -r \-\[\]\{\}\!\=\~\^\$\;\(\)\:\.\*\@\\\/\<\>\`\"\'\| 32 )}"  # set if not defined

export DB_SCHEMA=${DB_SCHEMA:-${WHOAMI}_lfcddemo}
# Schema-level demo source (tables intpk_sch/strpk_sch/dtix_sch). Per-table demo uses DB_SCHEMA.
export DB_SCHEMA_SCH="${DB_SCHEMA_SCH:-${DB_SCHEMA}_sch}"
export DB_PORT=${DB_PORT:-""}
export SECRETS_SCOPE=${SECRETS_SCOPE:-${WHOAMI}}

# functions used 

test_dba_master_connect() {
    test_db_connect "$DBA_USERNAME" "$DBA_PASSWORD" "$DB_HOST_FQDN" "$DB_PORT" "master" "${1:-""}"
}
test_dba_catalog_connect() {
    test_db_connect "$DBA_USERNAME" "$DBA_PASSWORD" "$DB_HOST_FQDN" "$DB_PORT" "$DB_CATALOG" "${1-""}"
}

test_user_catalog_connect() {
    test_db_connect "$USER_USERNAME" "$USER_PASSWORD" "$DB_HOST_FQDN" "$DB_PORT" "$DB_CATALOG" "${1-""}"
}

test_db_connect() {
    local dba_username=${1:-$DB_USERNAME}
    local dba_password=${2:-$DB_PASSWORD}
    local db_host_fqdn=${3:-$DB_HOST_FQDN}
    local db_port=${4:-$DB_PORT}
    local db_catalog=${5:-$DB_CATALOG}
    local timeout=${6:-${DB_LOGIN_TIMEOUT:-5}}

    echo "select 1" | sqlcmd -l "${timeout}" -d "$db_catalog" -S ${db_host_fqdn},${db_port} -U "${dba_username}" -P "${dba_password}" -C >/tmp/select1_stdout.$$ 2>/tmp/select1_stderr.$$
    if [[ $? == 0 ]]; then 
        echo "connect ok $dba_username@$db_host_fqdn:${db_port}/${db_catalog}"
    else 
        cat /tmp/select1_stdout.$$ /tmp/select1_stderr.$$ 
        return 1 
    fi
}

TEST_DB_CONNECT() {
    # Callers must prefix DB_USERNAME, DB_PASSWORD, and DB_CATALOG (and rely on DB_HOST_FQDN/DB_PORT).
    local RC
    echo "select 1" | SQLCLI >/dev/null 2>&1
    RC=$?
    if [[ $RC == 0 ]]; then 
        echo "connect ok $DB_USERNAME@$DB_HOST_FQDN:${DB_PORT}/${DB_CATALOG}"
    else
        echo "connect NOT ok $DB_USERNAME@$DB_HOST_FQDN:${DB_PORT}/${DB_CATALOG}"
    fi
    return $RC
}

# #############################################################################
# retrieve setting from secrets if exists

secrets_set_all_read() {
    local SECRETS_SCOPE="$SECRETS_SCOPE"
    local DB_EXIT_ON_ERROR="${DB_EXIT_ON_ERROR:-PRINT_RETURN}"

    if ! DB_EXIT_ON_ERROR="${DB_EXIT_ON_ERROR}" DBX secrets put-acl "$SECRETS_SCOPE" "account users" READ; then
        # try with users
        DB_EXIT_ON_ERROR="${DB_EXIT_ON_ERROR}" DBX secrets put-acl "$SECRETS_SCOPE" "users" READ
    fi
}

# return 0 to save
# return 1 to not save
should_save_secrets() {
    if [[ -z "$DELETE_DB_AFTER_SLEEP" ]] && [[ "${DB_HOST_CREATED}" == "1" || "${DB_PASSWORD_CHANGED}" == "1" ]]; then 
        echo "writing secrets for created database that won't be deleted"
        return 0
    elif [[  "${SECRETS_RETRIEVED}" == '1' && "${DB_PASSWORD_CHANGED}" == "1" ]] ; then
        echo "writing secrets for existing database with new DBA password"
        return 0
    else
        echo -e "don't save secrets. manually run if needed: \n put_secrets  \n put_secrets \${DB_HOST} json "    # json format for easier parsing"
        return 1
    fi
}
export -f should_save_secrets

save_before_secrets() {
    for k in DB_HOST DB_HOST_FQDN DB_PORT DB_CATALOG DBA_USERNAME DBA_PASSWORD USER_USERNAME USER_PASSWORD; do
        vars_before_secrets["$k"]="${!k}"
    done    
}
restore_before_secrets() {
    for k in "${!vars_before_secrets[@]}"; do 
        eval "$k='${vars_before_secrets["${k}"]}'"
    done    
}

get_secrets() {
    local secrets_key=${1:-"key_value"}
    if DBX ${DBX_PROFILE_SECRETS:+"--profile" "$DBX_PROFILE_SECRETS"} secrets get-secret "${SECRETS_SCOPE}" "${secrets_key}"; then
        v="$(jq -r '.value | @base64d' /tmp/dbx_stdout.$$)"
        CONNECTION_TYPE=""  # backward compat.  CONNECTION_TYPE="" when not present for SQLSERVER
        if [[ -n $v ]]; then 
            eval "$v"
            SECRETS_RETRIEVED=1 
            #echo "$v retrieved from databricks secrets" # DEBUG
        else
            return 1
        fi
    else
        return 1
    fi

}
export -f get_secrets

json_to_associative_array() {
    local -n json_to_associative_array_credentials="$1"  # nameref to associative array (passed by name)
    local json_file="$json_file"                         # path to JSON file

    while IFS='=' read -r key value; do
        value="${value%\'}"                               # strip trailing single quote
        value="${value#\'}"                               # strip leading single quote
        echo "$key=$value"
        json_to_associative_array_credentials["$key"]="$value"
    done < <(yq -o=shell "$json_file")
}
export -f json_to_associative_array

# LfcCredential V2 requires db_type ∈ {postgresql, mysql, sqlserver, oracle} (lowercase).
# CONNECTION_TYPE is the engine (e.g. MYSQL); DB_TYPE is often a cloud slug (e.g. azure-mysql).
lfc_secrets_v2_db_type() {
    case "${CONNECTION_TYPE^^}" in
        MYSQL|MARIADB) echo mysql; return 0 ;;
        POSTGRESQL|POSTGRES) echo postgresql; return 0 ;;
        SQLSERVER) echo sqlserver; return 0 ;;
        ORACLE) echo oracle; return 0 ;;
    esac
    local d="${DB_TYPE,,}"
    case "$d" in
        *mysql*|*mariadb*) echo mysql; return 0 ;;
        *oracle*) echo oracle; return 0 ;;
        *postgres*|*postgresql*) echo postgresql; return 0 ;;
        *sqlserver*|*sql-server*) echo sqlserver; return 0 ;;
        *-pg) echo postgresql; return 0 ;;
        mysql) echo mysql; return 0 ;;
        postgresql|postgres) echo postgresql; return 0 ;;
        sqlserver) echo sqlserver; return 0 ;;
        oracle) echo oracle; return 0 ;;
    esac
    return 1
}
export -f lfc_secrets_v2_db_type

put_secrets() {
    local secrets_key=${1:-"$DB_HOST"}
    local secretes_format=${2:-""}
    local key_value="${3:-""}"
    local secrets_key="${secrets_key}"

    # create secret scope if does not exist
    if ! DBX ${DBX_PROFILE_SECRETS:+"--profile" "$DBX_PROFILE_SECRETS"} secrets list-secrets "${SECRETS_SCOPE}"; then
        if ! DBX ${DBX_PROFILE_SECRETS:+"--profile" "$DBX_PROFILE_SECRETS"} secrets create-scope "${SECRETS_SCOPE}"; then
            cat /tmp/dbx_stderr.$$; return 1;
        fi
    fi

    if [[ -z "$key_value" ]] && [[ "${secretes_format}" == "json" ]]; then
      secrets_key="${secrets_key}_json"
      local LFC_SECRETS_V2_DB_TYPE
      if ! LFC_SECRETS_V2_DB_TYPE="$(lfc_secrets_v2_db_type)"; then
        echo "put_secrets: cannot map V2 db_type from CONNECTION_TYPE='${CONNECTION_TYPE}' DB_TYPE='${DB_TYPE}' (need postgresql|mysql|sqlserver|oracle)" >&2
        return 1
      fi
      key_value=$(yq -o json <<EOF
version: v2
cloud_db_type: $CLOUD_DB_TYPE
db_type: $LFC_SECRETS_V2_DB_TYPE
connection_type: $CONNECTION_TYPE
catalog: $DB_CATALOG  
schema: $DB_SCHEMA
name: $DB_HOST  
host_fqdn: $DB_HOST_FQDN  
port: $DB_PORT  
password: $USER_PASSWORD 
user: $USER_USERNAME  
replication_mode: both
cloud: 
  provider: ${CLOUD_DB_TYPE%%-*}
  location: $CLOUD_LOCATION
  resource_group: $RG_NAME
dba:
  user: $DBA_USERNAME 
  password: $DBA_PASSWORD  
EOF
      )

    else
        for k in DB_HOST DB_HOST_FQDN DB_PORT DB_CATALOG DBA_USERNAME DBA_PASSWORD USER_USERNAME USER_PASSWORD CONNECTION_TYPE; do
            key_value="export ${k}='${!k}';$key_value"
        done
    fi

    if ! DBX ${DBX_PROFILE_SECRETS:+"--profile" "$DBX_PROFILE_SECRETS"} secrets put-secret "${SECRETS_SCOPE}" "${secrets_key}" --string-value "$key_value"; then
        cat /tmp/dbx_stderr.$$; return 1;
    fi
}
export -f put_secrets

# #############################################################################

# Placeholder only when unset — do not wipe provider overrides from 01_* on re-source.
if ! declare -F SQLCLI >/dev/null; then
  SQLCLI() {
      echo "{@}"
  }
  export -f SQLCLI
fi

if ! declare -F SQLCLI_DBA >/dev/null; then
  SQLCLI_DBA() {
      DB_USERNAME="${DBA_USERNAME}" DB_PASSWORD="${DBA_PASSWORD}" DB_CATALOG="" SQLCLI "${@}"
  }
  export -f SQLCLI_DBA
fi

if ! declare -F SQLCLI_USER >/dev/null; then
  SQLCLI_USER() {
      DB_USERNAME="${USER_USERNAME}" DB_PASSWORD="${USER_PASSWORD}" SQLCLI "${@}"
  }
  export -f SQLCLI_USER
fi

# #############################################################################
# connection 

# input is stdin, $1=connection name $2=SECRETS_SCOPE
# output is at STATE[conn_create_json] STATE[conn_patch_json]
connection_spec_from_json() {
    local -n OUTPUT="${1}"

    local CONNECTION_NAME="${CONNECTION_NAME}"
    local SECRETS_SCOPE="${SECRETS_SCOPE}"

    OUTPUT[conn_create_json]=$(echo "${OUTPUT[secret_value_json]}" | jq --arg name "$CONNECTION_NAME" --arg scope "$SECRETS_SCOPE" '{
  name: ($name),
  connection_type: ((.connection_type // .db_type // "SQLSERVER") | ascii_upcase),
  comment: ("{\"secrets\": {\"scope\": \"" + $scope + "\", \"key\": \"" + .name + "\"}}"),
  options: ({
    host: .host_fqdn,
    port: (.port | tostring),
    user: .user,
    password: .password
  } + (if ((.connection_type // .db_type // "SQLSERVER") | ascii_upcase | IN("SQLSERVER", "MYSQL")) then {trustServerCertificate: "true"} else {} end))
}'
    )

    OUTPUT[conn_patch_json]=$(echo "${OUTPUT[conn_create_json]}" | jq 'del(.connection_type)')
}
export -f connection_spec_from_json

connection_spec_from_env() {
    local -n OUTPUT="${1}"

    OUTPUT[conn_create_json]=$(yq -o json <<EOF
name: $CONNECTION_NAME
connection_type: $CONNECTION_TYPE
comment: '{"secrets": {"scope": "$SECRETS_SCOPE", "key": "$DB_HOST"}}'
options: 
    host: $DB_HOST_FQDN
    port: $DB_PORT
    user: $USER_USERNAME
    password: $USER_PASSWORD
    $(if [[ "${CONNECTION_TYPE^^}" == "SQLSERVER" || "${CONNECTION_TYPE^^}" == "MYSQL" ]]; then printf "trustServerCertificate: true"; fi)
EOF
)
OUTPUT[conn_patch_json]=$(echo "${OUTPUT[conn_create_json]}" | jq 'del(.connection_type)')
}
export -f connection_spec_from_env

# allow all users to READ (use connection)
connection_set_all_read() {
    local CONNECTION_NAME="${CONNECTION_NAME}"
    local connection_permission='{ "changes": [ { "add": [ "USE_CONNECTION" ], "principal": "account users" } ] }'
    DB_EXIT_ON_ERROR="PRINT_EXIT" DBX api patch /api/2.1/unity-catalog/permissions/connection/"${CONNECTION_NAME}" --json "$connection_permission"
}
export -f connection_set_all_read


connection_create_or_replace() {
    local -n OUTPUT="${1}"
    #if [[ -z "${OUTPUT[*]}" ]]; then echo "connection_create_or_replace \$1 not specified"; kill -INT $$; fi 

    # get the connection name
    local CONNECTION_NAME="$(echo "${OUTPUT[conn_create_json]}" | jq -r '.name')"
    local CONNECTION_NAME_URI
    CONNECTION_NAME_URI="$(echo -n "$CONNECTION_NAME" | jq -sRr @uri)"
    OUTPUT[connection_created]=""

    # create or replace (patch uses same options as create via conn_patch_json)
    if ! DBX connections get "$CONNECTION_NAME"; then
        DB_EXIT_ON_ERROR="PRINT_EXIT" DBX api post /api/2.1/unity-catalog/connections --json "${OUTPUT[conn_create_json]}"
        OUTPUT[connection_created]=1
    else 
        DB_EXIT_ON_ERROR="PRINT_EXIT" DBX api patch /api/2.1/unity-catalog/connections/"${CONNECTION_NAME_URI}" --json "${OUTPUT[conn_patch_json]}"
    fi

    # save the connection id
    CONNECTION_ID=$(jq -r '.connection_id' /tmp/dbx_stdout.$$)
    OUTPUT[CONNECTION_ID]="${CONNECTION_ID}"
    export CONNECTION_ID

    # make connection avail to all
    CONNECTION_NAME="$CONNECTION_NAME" connection_set_all_read 
}
export -f connection_create_or_replace

# Create a Lakehouse Federation foreign catalog backed by CONNECTION_NAME.
# INPUT via env: CONNECTION_NAME, SOURCE_TYPE / CONNECTION_TYPE / DB_TYPE, DB_CATALOG
# OUTPUT nameref keys: FOREIGN_CATALOG_NAME, foreign_catalog_created
foreign_catalog_create_or_replace() {
    local -n OUTPUT="${1}"
    local FC_NAME="${CONNECTION_NAME}"
    local CONN_TYPE=""
    local fc_create_json

    OUTPUT[FOREIGN_CATALOG_NAME]="${FC_NAME}"
    OUTPUT[foreign_catalog_created]=""
    export FOREIGN_CATALOG_NAME="${FC_NAME}"

    # Prefer SOURCE_TYPE (demo pipeline), then CONNECTION_TYPE, then DB_TYPE map,
    # then live UC connection_type (avoids stale MYSQL left in the shell).
    if [[ -n "${SOURCE_TYPE:-}" ]]; then
        CONN_TYPE="${SOURCE_TYPE}"
    elif [[ -n "${CONNECTION_TYPE:-}" ]]; then
        CONN_TYPE="${CONNECTION_TYPE}"
    else
        case "${DB_TYPE:-}" in
            postgres|postgresql) CONN_TYPE="POSTGRESQL" ;;
            sqlserver|mssql)     CONN_TYPE="SQLSERVER" ;;
            mysql|mariadb)       CONN_TYPE="MYSQL" ;;
        esac
    fi
    if [[ -z "${CONN_TYPE}" ]]; then
        if DBX connections get "${FC_NAME}"; then
            CONN_TYPE="$(jq -r '.connection_type // empty' /tmp/dbx_stdout.$$)"
        fi
    fi
    CONN_TYPE="$(echo "${CONN_TYPE}" | tr '[:lower:]' '[:upper:]')"

    if [[ "${CONN_TYPE}" == "POSTGRESQL" || "${CONN_TYPE}" == "SQLSERVER" ]]; then
        if [[ -z "${DB_CATALOG:-}" ]]; then
            echo "ERROR: foreign catalog for ${CONN_TYPE} requires DB_CATALOG (database option)" >&2
            return 1
        fi
    fi

    fc_create_json="$(
      CONNECTION_NAME="${CONNECTION_NAME}" \
      DB_CATALOG="${DB_CATALOG:-}" \
      CONN_TYPE="${CONN_TYPE}" \
      jq -n '
        {
          name: env.CONNECTION_NAME,
          connection_name: env.CONNECTION_NAME,
          catalog_type: "FOREIGN",
          comment: ("Federated catalog for " + env.CONNECTION_NAME)
        }
        | if (env.CONN_TYPE | ascii_upcase | IN("POSTGRESQL", "SQLSERVER")) then
            . + {options: {database: env.DB_CATALOG}}
          else .
          end
      '
    )" || return 1

    if ! DBX catalogs get "${FC_NAME}"; then
        DB_EXIT_ON_ERROR="PRINT_EXIT" DBX api post /api/2.1/unity-catalog/catalogs --json "${fc_create_json}"
        OUTPUT[foreign_catalog_created]=1
    fi
}
export -f foreign_catalog_create_or_replace


# make sure executables are there are with correct versions
for exe in curl ipcalc pwgen ttyd tmux wget; do
    if ! command -v $exe &> /dev/null; then
    echo -e "\n
        wget command does not exist.  please install via the following and rerun.

        brew install $exe                      # install $exe
        export PATH=/opt/homebrew/bin:\$PATH   # set PATH
    "
    fi
done