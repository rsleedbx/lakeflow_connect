#!/usr/bin/env bash

# error out when undeclared variable is used
set -u 

# set tags that will resources remove using cloud scheduler
if ! declare -p REMOVE_AFTER &> /dev/null; then
export REMOVE_AFTER=$(date --date='+0 day' +%Y-%m-%d)   # blank is do not delete
fi

# stop after sleep
if ! declare -p STOP_AFTER_SLEEP &> /dev/null; then
export STOP_AFTER_SLEEP=${STOP_AFTER_SLEEP:-"31m"}      # blank is do not stop
fi

# delete database after sleep
if ! declare -p DELETE_DB_AFTER_SLEEP &> /dev/null; then
export DELETE_DB_AFTER_SLEEP=${DELETE_DB_AFTER_SLEEP:-"61m"}    # blank is do not delete
fi

# delete lakeflow objects after sleep 
if ! declare -p DELETE_PIPELINES_AFTER_SLEEP &> /dev/null; then
export DELETE_PIPELINES_AFTER_SLEEP=${DELETE_PIPELINES_AFTER_SLEEP:-"63m"}  # blank is do not delete
fi

# save credentials in secrets so that password reset won't be required
if ! declare -p GET_DBX_SECRETS &> /dev/null; then
export GET_DBX_SECRETS=1
fi
if ! declare -p PUT_DBX_SECRETS &> /dev/null; then
export PUT_DBX_SECRETS=1
fi
# used to recover from invalid secrets load
declare -A vars_before_secrets
export vars_before_secrets
export SECRETS_RETRIEVED=0  # indicate secrets was successfully retrieved
export DBX_PROFILE=${DBX_PROFILE:-"DEFAULT"}
export DBX_PROFILE_SECRETS=${DBX_PROFILE_SECRETS:-"DEFAULT"}

# permissive firewall by default.  DO NOT USE WITH PRODUCTION SCHEMA or DATA
export DB_FIREWALL_CIDRS="${DB_FIREWALL_CIDRS:-"0.0.0.0/0"}"

export CLOUD_LOCATION="${CLOUD_LOCATION:-"East US"}"

export CDC_CT_MODE=${CDC_CT_MODE:-"BOTH"}   # ['BOTH'|'CT'|'CDC'|'NONE']

export AZ_DB_TYPE=${AZ_DB_TYPE:-""}         # zmi|zsql

export CONNECTION_NAME="${CONNECTION_NAME:-""}"

export DB_HOST=${DB_HOST:-""}
export DB_HOST_FQDN=${DB_HOST_FQDN:-""}
export DB_CATALOG=${DB_CATALOG:-""}
export DBX_USERNAME=${DBX_USERNAME:-""}
export DBA_PASSWORD=${DBA_PASSWORD:-""}
export USER_PASSWORD=${USER_PASSWORD:-""}
export az_tenantDefaultDomain=${az_tenantDefaultDomain:-""}
export az_id=${az_id:-""}
export az_user_name=${az_user_name:-""}

# display AZ commands
AZ() {
    PWMASK="$@"
    PWMASK="${PWMASK//$DBA_PASSWORD/\$DBA_PASSWORD}"
    PWMASK="${PWMASK//$USER_PASSWORD/\$USER_PASSWORD}"
    PWMASK="${PWMASK//$az_tenantDefaultDomain/\$az_tenantDefaultDomain}"
    PWMASK="${PWMASK//$az_id/\$az_id}"
    PWMASK="${PWMASK//$az_user_name/\$az_user_name}"
    echo -n az "${PWMASK}"
    az "$@" >/tmp/az_stdout.$$ 2>/tmp/az_stderr.$$
    rc=$?
    if [[ "$rc" != "0" ]]; then

        echo ". failed with $rc"
        return 1
    else
        echo ""
    fi
}

# display AZ commands
GCLOUD() {
    PWMASK="$@"
    PWMASK="${PWMASK//$DBA_PASSWORD/\$DBA_PASSWORD}"
    PWMASK="${PWMASK//$USER_PASSWORD/\$USER_PASSWORD}"
    echo -n gcloud "${PWMASK}" --quiet --format=json
    gcloud "$@" --quiet --format=json >/tmp/gcloud_stdout.$$ 2>/tmp/gcloud_stderr.$$
    rc=$?
    if [[ "$rc" != "0" ]]; then

        echo ". failed with $rc"
        return 1
    else
        echo ""
    fi
}

DBX() {
local rc
    PWMASK="$@"
    PWMASK="${PWMASK//$DBA_PASSWORD/\$DBA_PASSWORD}"
    PWMASK="${PWMASK//$USER_PASSWORD/\$USER_PASSWORD}"
    PWMASK="${PWMASK//$DBX_USERNAME/\$DBX_USERNAME}"
    echo -n databricks "${PWMASK}"
    databricks "$@" >/tmp/dbx_stdout.$$ 2>/tmp/dbx_stderr.$$
    rc=$?
    if [[ "$rc" != "0" ]]; then
        echo " failed with $rc"
        return 1
    else
        echo ""
    fi
}

SQLCMD() {
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
    rc=$?
    if [[ "$rc" != "0" ]]; then

        echo ". failed with $rc"
        return 1
    else
        echo ""
    fi
}   

export WHOAMI=${WHOAMI:-$(whoami)}
WHOAMI="$(echo "$WHOAMI" | tr -d '\-\.\_')"


if [[ -z "$DBX_USERNAME" ]]; then
    if ! DBX current-user me; then
        DBX_USERNAME="$az_user_name"
    else
        DBX_USERNAME="$(jq -r .userName /tmp/dbx_stdout.$$)"
    fi 
fi
export DBX_USERNAME

export RG_NAME=${RG_NAME:-${WHOAMI}-rg}                # resource group name

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

# DB and catalog basename
export DB_BASENAME=${DB_BASENAME:-$(pwgen -1AB 8)}        # lower case, name seen on internet
export CATALOG_BASENAME=${CATALOG_BASENAME:-$(pwgen -1AB 8)}

# special char mess up eval and bash string substitution
export DBA_PASSWORD="${DBA_PASSWORD:-$(pwgen -1y   -r \[\]\!\=\~\^\$\;\(\)\:\.\*\@\\\>\`\"\'\| 32 )}"  # set if not defined
export USER_PASSWORD="${USER_PASSWORD:-$(pwgen -1y -r \[\]\!\=\~\^\$\;\(\)\:\.\*\@\\\>\`\"\'\| 32 )}"  # set if not defined

export DB_SCHEMA=${DB_SCHEMA:-${WHOAMI}}
export DB_PORT=${DB_PORT:-1433}
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
    local dba_username=$1
    local dba_password=$2
    local db_host_fqdn=$3
    local db_port=$4
    local db_catalog=$5
    local timeout=${6:-5}

    echo "select 1" | sqlcmd -l "${timeout}" -d "$db_catalog" -S ${db_host_fqdn},${db_port} -U "${dba_username}" -P "${dba_password}" -C >/tmp/select1_stdout.$$ 2>/tmp/select1_stderr.$$
    if [[ $? == 0 ]]; then 
        echo "connect ok $dba_username@$db_host_fqdn:${db_port}/${db_catalog}"
    else 
        cat /tmp/select1_stdout.$$ /tmp/select1_stderr.$$ 
        return 1 
    fi
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
    for k in DB_HOST DB_HOST_FQDN DB_PORT DB_CATALOG DBA_USERNAME DBA_PASSWORD USER_USERNAME USER_PASSWORD; do
        key_value="export ${k}='${!k}';$key_value"
    done
    if ! DBX ${DBX_PROFILE_SECRETS:+"--profile" "$DBX_PROFILE_SECRETS"} secrets put-secret "${SECRETS_SCOPE}" "${secrets_key}" --string-value "$key_value"; then
        cat /tmp/dbx_stderr.$$; return 1;
    fi
}
export put_secrets

# #############################################################################
