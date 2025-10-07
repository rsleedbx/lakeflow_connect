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
export STOP_AFTER_SLEEP=${STOP_AFTER_SLEEP:-"127m"}      # blank is do not stop
fi

# delete database after sleep
if ! declare -p DELETE_DB_AFTER_SLEEP &> /dev/null; then
export DELETE_DB_AFTER_SLEEP=${DELETE_DB_AFTER_SLEEP:-"131m"}    # blank is do not delete
fi

# delete lakeflow objects after sleep 
if ! declare -p DELETE_PIPELINES_AFTER_SLEEP &> /dev/null; then
export DELETE_PIPELINES_AFTER_SLEEP=${DELETE_PIPELINES_AFTER_SLEEP:-"137m"}  # blank is do not delete
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

# display AZ commands
AZ() {
    local DB_EXIT_ON_ERROR=${DB_EXIT_ON_ERROR:-""}
    # stdout and stderr file names
    local DB_OUT_SUFFIX=${DB_OUT_SUFFIX:-""}
    local DB_STDOUT=${DB_STDOUT:-"/tmp/az_stdout${DB_OUT_SUFFIX:+_${DB_OUT_SUFFIX}}.$$"}
    local DB_STDERR=${DB_STDERR:-"/tmp/az_stderr${DB_OUT_SUFFIX:+_${DB_OUT_SUFFIX}}.$$"}
    local RC

    PWMASK="$@"
    PWMASK="${PWMASK//$DBA_PASSWORD/\$DBA_PASSWORD}"
    PWMASK="${PWMASK//$USER_PASSWORD/\$USER_PASSWORD}"
    PWMASK="${PWMASK//$az_tenantDefaultDomain/\$az_tenantDefaultDomain}"
    PWMASK="${PWMASK//$az_id/\$az_id}"
    PWMASK="${PWMASK//$az_user_name/\$az_user_name}"
    echo -n az "${PWMASK}"
    az "$@" >${DB_STDOUT} 2>${DB_STDERR}

    RC=$?
    RC="$RC" DB_EXIT_ON_ERROR="$DB_EXIT_ON_ERROR" DB_STDOUT="$DB_STDOUT" DB_STDERR="$DB_STDERR" CONT_OR_EXIT
    return $?
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

    DB_EXIT_ON_ERROR="PRINT_EXIT" AZ account show
    export az_id="${az_id:-$(jq -r '.id' /tmp/az_stdout.$$)}" 
    export az_tenantDefaultDomain="${az_tenantDefaultDomain:-$(jq -r '.tenantDefaultDomain' /tmp/az_stdout.$$)}"
    export az_user_name="${az_user_name:-$(jq -r '.user.name' /tmp/az_stdout.$$)}"

    # set default location
    if [[ -n "${CLOUD_LOCATION}" ]]; then 
        DB_EXIT_ON_ERROR="PRINT_EXIT" AZ configure ${CLOUD_LOCATION:+--defaults location="${CLOUD_LOCATION}"}
    fi

    # create resource group
    if ! AZ group show --resource-group "${RG_NAME}" ; then
        # multiples tags are defined correctly below.  NOT A MISTAKE
        DB_EXIT_ON_ERROR="PRINT_EXIT" AZ group create --resource-group "${RG_NAME}" \
            --tags "Owner=${DBX_USERNAME}" "${REMOVE_AFTER:+RemoveAfter=${REMOVE_AFTER}}"
    fi

    # set default resource group
    RG_NAME=$(jq -r .name /tmp/az_stdout.$$)
    DB_EXIT_ON_ERROR="PRINT_EXIT" AZ configure --defaults group="${RG_NAME}"    

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

# display AZ commands
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

    PWMASK="${*}"
    PWMASK="${PWMASK//$DBA_PASSWORD/\$DBA_PASSWORD}"
    PWMASK="${PWMASK//$USER_PASSWORD/\$USER_PASSWORD}"
    PWMASK="${PWMASK//$DBX_USERNAME/\$DBX_USERNAME}"
    PWMASK="${PWMASK//$DBA_USERNAME/\$DBA_USERNAME}"
    PWMASK="${PWMASK//$USER_USERNAME/\$USER_USERNAME}"
    PWMASK="${PWMASK//$DB_CATALOG/\$DB_CATALOG}"

    echo "sqlcmd -d '$DB_CATALOG' -S ${DB_HOST_FQDN},${DB_PORT} -U '${DBA_USERNAME}' -P \${DBA_PASSWORD} -C -l ${DB_LOGIN_TIMEOUT}"

    if [[ -t 0 ]]; then
        # stdin is attached
        sqlcmd -d "$DB_CATALOG" -S "${DB_HOST_FQDN},${DB_PORT}" -U "${DBA_USERNAME}" -P "${DBA_PASSWORD}" -C -l "${DB_LOGIN_TIMEOUT}" "${@}"
    else
        # running in batch mode
        sqlcmd -d "$DB_CATALOG" -S "${DB_HOST_FQDN},${DB_PORT}" -U "${DBA_USERNAME}" -P "${DBA_PASSWORD}" -C -l "${DB_LOGIN_TIMEOUT}" -h -1 "${@}" >${DB_STDOUT} 2>${DB_STDERR} 
    fi

    RC=$?
    RC="$RC" DB_EXIT_ON_ERROR="$DB_EXIT_ON_ERROR" DB_STDOUT="$DB_STDOUT" DB_STDERR="$DB_STDERR" CONT_OR_EXIT
    return $?
}
export -f SQLCMD

SQLCMD_OLD() {
    local DB_EXIT_ON_ERROR=${DB_EXIT_ON_ERROR:-""}
    # stdout and stderr file names
    local DB_OUT_SUFFIX=${DB_OUT_SUFFIX:-""}
    local DB_STDOUT=${DB_STDOUT:-"/tmp/sqlcmd_stdout${DB_OUT_SUFFIX:+_${DB_OUT_SUFFIX}}.$$"}
    local DB_STDERR=${DB_STDERR:-"/tmp/sqlcmd_stderr${DB_OUT_SUFFIX:+_${DB_OUT_SUFFIX}}.$$"}
    local RC

    PWMASK="$@"
    PWMASK="${PWMASK//$DBA_PASSWORD/\$DBA_PASSWORD}"
    PWMASK="${PWMASK//$USER_PASSWORD/\$USER_PASSWORD}"
    echo -n sqlcmd "${PWMASK}"
    if ! [ -t 0 ]; then
        # echo "redirect stdin"
        sqlcmd "$@" >/tmp/sqlcmd_stdout.$$ 2>/tmp/sqlcmd_stderr.$$
    else
        sqlcmd "$@" >/tmp/sqlcmd_stdout.$$ 2>/tmp/sqlcmd_stderr.$$
    fi    

    RC=$?
    RC="$RC" DB_EXIT_ON_ERROR="$DB_EXIT_ON_ERROR" DB_STDOUT="$DB_STDOUT" DB_STDERR="$DB_STDERR" CONT_OR_EXIT
    return $?
}  
export -f SQLCMD 

PSQL() {
    local DB_USERNAME=${DB_USERNAME:-${USER_USERNAME}}
    local DB_PASSWORD=${DB_PASSWORD:-${USER_PASSWORD}}
    local DB_HOST_FQDN=${DB_HOST_FQDN}
    local DB_PORT=${DB_PORT:-${1433}}
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

if [[ -z "$DBX_USERNAME" ]]; then
    DB_EXIT_ON_ERROR="PRINT_EXIT" DBX current-user me
    DBX_USERNAME="$(jq -r .userName /tmp/dbx_stdout.$$)"
fi
export DBX_USERNAME
export DBX_USERNAME_NO_DOMAIN="${DBX_USERNAME%%@*}"                  # remove everything after the first @
export DBX_USERNAME_NO_DOMAIN_DOT="${DBX_USERNAME_NO_DOMAIN//./_}"   # . to _

export RG_NAME=${RG_NAME:-${WHOAMI}-rg}                # resource group name
export DBX_WORKSPACE_PATH=${DBX_WORKSPACE_PATH:-"/Users/${DBX_USERNAME}/lfcddemokit"}

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

put_secrets() {
    local secrets_key=${1:-"$DB_HOST"}
    local key_value=""
    # create secret scope if does not exist
    if ! DBX ${DBX_PROFILE_SECRETS:+"--profile" "$DBX_PROFILE_SECRETS"} secrets list-secrets "${SECRETS_SCOPE}"; then
        if ! DBX ${DBX_PROFILE_SECRETS:+"--profile" "$DBX_PROFILE_SECRETS"} secrets create-scope "${SECRETS_SCOPE}"; then
            cat /tmp/dbx_stderr.$$; return 1;
        fi
    fi
    for k in DB_HOST DB_HOST_FQDN DB_PORT DB_CATALOG DBA_USERNAME DBA_PASSWORD USER_USERNAME USER_PASSWORD CONNECTION_TYPE; do
        key_value="export ${k}='${!k}';$key_value"
    done
    if ! DBX ${DBX_PROFILE_SECRETS:+"--profile" "$DBX_PROFILE_SECRETS"} secrets put-secret "${SECRETS_SCOPE}" "${secrets_key}" --string-value "$key_value"; then
        cat /tmp/dbx_stderr.$$; return 1;
    fi
}
export put_secrets

# #############################################################################

# should be overridden by the individual provider
SQLCLI() {
    echo "{@}"
}
export -f SQLCLI

# can be left as is
SQLCLI_DBA() {
    DB_USERNAME="${DBA_USERNAME}" DB_PASSWORD="${DBA_PASSWORD}" DB_CATALOG="" SQLCLI "${@}"
}
export -f SQLCLI_DBA

SQLCLI_USER() {
    DB_USERNAME="${USER_USERNAME}" DB_PASSWORD="${USER_PASSWORD}" SQLCLI "${@}"
}
export -f SQLCLI_USER

# #############################################################################

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