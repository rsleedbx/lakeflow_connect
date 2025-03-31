#!/usr/bin/env bash

# error out when undeclared variable is used
set -u 

# set tags that will resources remove using cloud scheduler
export REMOVE_AFTER=$(date --date='+0 day' +%Y-%m-%d)

# stop after sleep
export STOP_AFTER_SLEEP=${STOP_AFTER_SLEEP:-"31m"}

# delete database after sleep
export DELETE_DB_AFTER_SLEEP=${DELETE_DB_AFTER_SLEEP:-"31m"}    # 31m

# delete lakeflow objects after sleep 
export DELETE_PIPELINES_AFTER_SLEEP=${DELETE_PIPELINES_AFTER_SLEEP:-"61m"}

# permissive firewall by default.  DO NOT USE WITH PRODUCTION SCHEMA or DATA
export DB_FIREWALL_CIDRS="${DB_FIREWALL_CIDRS:-"0.0.0.0/0"}"

export CLOUD_LOCATION="${CLOUD_LOCATION:-"East US"}"

export CDC_CT_MODE=${CDC_CT_MODE:-"BOTH"}   # ['BOTH'|'CT'|'CDC'|'NONE']

export AZ_DB_TYPE=${AZ_DB_TYPE:-""}         # zmi|zsql
export DB_HOST=${DB_HOST:-""}
export DB_HOST_FQDN=${DB_HOST_FQDN:-""}
export DB_CATALOG=${DB_CATALOG:-""}
export DBX_USERNAME=${DBX_USERNAME:-""}
export DBA_PASSWORD=${DBA_PASSWORD:-""}
export USER_PASSWORD=${USER_PASSWORD:-""}
export az_tenantDefaultDomain=${az_tenantDefaultDomain:-""}
export az_id=${az_id:-""}

# display AZ commands
AZ() {
    PWMASK="$@"
    PWMASK="${PWMASK//$DBA_PASSWORD/\$DBA_PASSWORD}"
    PWMASK="${PWMASK//$USER_PASSWORD/\$USER_PASSWORD}"
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

DBX() {
local rc
    PWMASK="$@"
    PWMASK="${PWMASK//$DBA_PASSWORD/\$DBA_PASSWORD}"
    PWMASK="${PWMASK//$USER_PASSWORD/\$USER_PASSWORD}"
    echo -n databricks "${PWMASK}"
    databricks ${DATABRICKS_CONFIG_PROFILE:+--profile "$DATABRICKS_CONFIG_PROFILE"} "$@" >/tmp/dbx_stdout.$$ 2>/tmp/dbx_stderr.$$
    rc=$?
    if [[ "$rc" != "0" ]]; then
        echo " failed with $rc"
        return 1
    else
        echo ""
    fi
}

export WHOAMI=${WHOAMI:-$(whoami | tr -d .)}

if [[ -z "$DBX_USERNAME" ]]; then
    if ! DBX current-user me; then
        if ! AZ account show; then
            cat /tmp/dbx_stderr.$$ /tmp/az_stderr.$$
            return 1
        fi
        DBX_USERNAME="$(jq -r .user.name /tmp/az_stdout.$$)"
        if [[ -z "$az_id" ]] || [[ -z "$az_tenantDefaultDomain" ]]; then
            read -rd "\n" az_id az_tenantDefaultDomain <<< "$(jq -r '.id, .tenantDefaultDomain' /tmp/az_stdout.$$)"
            export az_id
            export az_tenantDefaultDomain
        fi
    else
        DBX_USERNAME="$(jq -r .userName /tmp/dbx_stdout.$$)"
    fi 
fi
export DBX_USERNAME

# used when creating.  preexisting db admin will be used
export DBA_USERNAME=${DBA_USERNAME:-$(pwgen -1AB 8)}        # GCP hardcoded to defaults to sqlserver.  Make it same for Azure
export USER_USERNAME=${USER_USERNAME:-$(pwgen -1AB 8)}      # set if not defined

export RG_NAME=${RG_NAME:-${WHOAMI}-lfcs}               # resource group name

export USE_DBX_SECRETS=""

# return 3 variables
read_fqdn_dba_if_host(){
local DB_HOST
local DB_HOST_FQDN
local DBA_USERNAME
    # assume list
    read -rd "\n" DB_HOST <<< "$(jq -r 'first(.[]) | .name' /tmp/az_stdout.$$ 2>/dev/null)" 
    # assume not a list
    if [[ -n "${DB_HOST}" ]]; then
        read -rd "\n" DB_HOST_FQDN DBA_USERNAME <<< "$(jq -r 'first(.[] | select(.fullyQualifiedDomainName!=null)) | .fullyQualifiedDomainName, .administratorLogin' /tmp/az_stdout.$$)"
    else
        read -rd "\n" DB_HOST <<< "$(jq -r '.name' /tmp/az_stdout.$$ 2>/dev/null)"
        if [[ -n "${DB_HOST}" ]]; then
            read -rd "\n" DB_HOST_FQDN DBA_USERNAME <<< "$(jq -r '.fullyQualifiedDomainName, .administratorLogin' /tmp/az_stdout.$$)"
        fi
    fi
    echo -e "$DB_HOST\n$DB_HOST_FQDN\n$DBA_USERNAME\n"
}

# return 1 variable
set_mi_fqdn_dba_host() {
    echo -e "${DB_HOST_FQDN/${DB_HOST}./${DB_HOST}.public.}"
}

# DB and catalog basename
export DB_BASENAME=${DB_BASENAME:-$(pwgen -1AB 8)}        # lower case, name seen on internet
export CATALOG_BASENAME=${CATALOG_BASENAME:-$(pwgen -1AB 8)}

export DB_SCHEMA=${DB_SCHEMA:-${WHOAMI}}
export DB_PORT=${DB_PORT:-1433}

export DBA_PASSWORD="${DBA_PASSWORD:-$(pwgen -1y -r \:\.\@\\\>\`\"\'\| 16 )}"  # set if not defined
export USER_PASSWORD="${USER_PASSWORD:-$(pwgen -1y -r \:\.\@\\\>\`\"\'\| 16 )}"  # set if not defined

# functions used 

test_db_connect() {
    local dba_username=$1
    local dba_password=$2
    local db_host_fqdn=$3
    local db_port=$4
    local db_catalog=$5

    echo "select 1" | sqlcmd -d "$db_catalog" -S ${db_host_fqdn},${db_port} -U "${dba_username}" -P "${dba_password}" -C -l 60 >/tmp/select1_stdout.$$ 2>/tmp/select1_stderr.$$
    if [[ $? == 0 ]]; then 
        echo "connect ok $dba_username@$db_host_fqdn:${db_port}/${db_catalog}"
    else 
        cat /tmp/select1_stdout.$$ /tmp/select1_stderr.$$ 
        return 1 
    fi
}

# NOT USED
dba_username_update_if_different() {
    # update DBA_USERNAME if different
    administratorLogin=$1
    if [[ "$DBA_USERNAME" != "$administratorLogin" ]]; then
        if DBX secrets create-scope "${SECRETS_SCOPE}"; then
            if ! DBX secrets put-secret "${SECRETS_SCOPE}" DBA_USERNAME --string-value "${DBA_USERNAME}"; then
                echo "failed."
                return 1
            fi
            DBA_USERNAME=$administratorLogin
            export DBA_USERNAME
        fi
    fi
}

# #############################################################################

if [[ -n "${CLOUD_LOCATION}" ]]; then 
    if ! AZ configure --defaults location="${CLOUD_LOCATION}" ; then
        cat /tmp/az_stderr.$$; return 1
    fi
fi

# #############################################################################
# create resource group if not exists
# https://learn.microsoft.com/en-us/azure/azure-resource-manager/management/manage-resource-groups-cli

# multiples tags are defined correctly below.  NOT A MISTAKE
if ! AZ group show --resource-group "${RG_NAME}" ; then
    if ! AZ group create --resource-group "${RG_NAME}" --tags "Owner=${DBX_USERNAME}" "${REMOVE_AFTER:+RemoveAfter=${REMOVE_AFTER}}" ; then
        cat /tmp/az_stderr.$$; return 1
    fi
fi
if ! AZ configure --defaults group="${RG_NAME}"; then 
    cat /tmp/az_stderr.$$; return 1
fi

echo "az group ${WHOAMI}: https://portal.azure.com/#@${az_tenantDefaultDomain}/resource/subscriptions/${az_id}/resourceGroups/${WHOAMI}/overview"
echo ""
