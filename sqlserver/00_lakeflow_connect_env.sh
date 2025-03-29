#!/usr/bin/env bash

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
    echo -n databricks "${@}"
    databricks "$@" >/tmp/dbx_stdout.$$ 2>/tmp/dbx_stderr.$$
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

export DBA_USERNAME=${DBA_USERNAME:-sqlserver}          # GCP hardcoded to defaults to sqlserver.  Make it same for Azure
export USER_USERNAME=${USER_USERNAME:-$WHOAMI}          # set if not defined

export RG_NAME=${RG_NAME:-${WHOAMI}-lfcs}               # resource group name

export USE_DBX_SECRETS=""

read_fqdn_dba_if_host(){
    # assume list
    read -rd "\n" DB_HOST <<< "$(jq -r 'first(.[]) | .name' /tmp/az_stdout.$$ 2>/dev/null)" 
    # assume not a list
    if [[ -n "${DB_HOST}" ]]; then
        read -rd "\n" DB_HOST_FQDN DBA_USERNAME <<< "$(jq -r 'first(.[]) | .fullyQualifiedDomainName, .administratorLogin' /tmp/az_stdout.$$)"
        export DB_HOST DB_HOST_FQDN DBA_USERNAME
    else
        read -rd "\n" DB_HOST <<< "$(jq -r '.name' /tmp/az_stdout.$$ 2>/dev/null)"
        if [[ -n "${DB_HOST}" ]]; then
            read -rd "\n" DB_HOST_FQDN DBA_USERNAME <<< "$(jq -r '.fullyQualifiedDomainName, .administratorLogin' /tmp/az_stdout.$$)"
            export DB_HOST DB_HOST_FQDN DBA_USERNAME
        fi
    fi
}

set_mi_fqdn_dba_host() {
export DB_HOST_FQDN="${DB_HOST_FQDN/${DB_HOST}./${DB_HOST}.public.}"
}

# prefer az sql server if exists
if [[ -z "$DB_HOST" ]] && [[ -z "$AZ_DB_TYPE" || "$AZ_DB_TYPE" == "zsql" ]]; then
    if AZ sql server list --resource-group "${RG_NAME}"; then
        echo "DB_HOST not set.  checking az sql server list" 
        read_fqdn_dba_if_host       
        export DB_HOST DB_HOST_FQDN DBA_USERNAME DB_PORT=1433
    fi
    if [[ -n "$DB_HOST" ]] && [[ -z "$DB_CATALOG" ]] && AZ sql db list -s "$DB_HOST" --resource-group "${RG_NAME}"; then
        echo "DB_CATALOG not set. checking az sql db list"
        DB_CATALOG="$(jq -r 'first(.[] | select(.name != "master") | .name)' /tmp/az_stdout.$$)"
        export DB_CATALOG
    fi
    if [[ -n "$DB_HOST" ]]; then
        echo "az sql server: $DBA_USERNAME@$DB_HOST_FQDN:$DB_PORT/$DB_CATALOG"
    fi
fi

# check az sql mi if exists
if [[ -z "$DB_HOST" ]] && [[ -z "$AZ_DB_TYPE" || "$AZ_DB_TYPE" == "zmi" ]]; then
    if AZ sql mi list --resource-group "${RG_NAME}"; then
        echo "DB_HOST not set.  checking az sql mi list"
        read_fqdn_dba_if_host
        set_mi_fqdn_dba_host
        export DB_HOST DB_HOST_FQDN DBA_USERNAME DB_PORT=3342
    fi
    if [[ -n "$DB_HOST" ]] && [[ -z "$DB_CATALOG" ]] && AZ sql midb list --mi "$DB_HOST" --resource-group "${RG_NAME}"; then
        echo "DB_CATALOG not set. checking az sql db list"
        DB_CATALOG="$(jq -r 'first(.[] | select(.name != "master") | .name)' /tmp/az_stdout.$$)"
        export DB_CATALOG
    fi
    if [[ -n "$DB_HOST" ]]; then
        echo "az sql mi: $DBA_USERNAME@$DB_HOST_FQDN:$DB_PORT/$DB_CATALOG"
    fi
fi

export DB_BASENAME=${DB_HOST:-$(pwgen -1AB 8)}        # lower case, name seen on internet

# create a new host name
export DB_HOST=${DB_HOST:-$DB_BASENAME}

# create a new catalog
export DB_CATALOG=${DB_CATALOG:-$(pwgen -1AB 8)}

export DB_SCHEMA=${DB_SCHEMA:-${WHOAMI}}
export DB_PORT=${DB_PORT:-1433}

export SECRETS_SCOPE="${WHOAMI}_${DB_HOST}"

# set or use existing DBA_PASSWORD
if [[ -n "$USE_DBX_SECRETS" ]]; then
    export DBA_PASSWORD="$(databricks secrets get-secret ${SECRETS_SCOPE} DBA_PASSWORD 2>/dev/null | jq -r .value | base64 --decode)"
fi

if [[ -z "$DBA_PASSWORD" ]]; then 
    export DBA_PASSWORD="${DBA_PASSWORD:-$(pwgen -1y -r \.\@\\\>\`\"\'\| 16 )}"  # set if not defined
fi

# set or use existing USER_PASSWORD
if [[ -n "$USE_DBX_SECRETS" ]]; then
    export USER_PASSWORD=$(databricks secrets get-secret ${SECRETS_SCOPE} USER_PASSWORD 2>/dev/null | jq -r .value | base64 --decode)
fi

if [[ -z $USER_PASSWORD ]]; then 
    export USER_PASSWORD=${USER_PASSWORD:-$(pwgen -1y -r \.\@\\\>\`\"\'\| 16 )}  # set if not defined
fi  

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
        echo "databricks secrets put-secret ${SECRETS_SCOPE} DBA_USERNAME running"
        databricks secrets create-scope ${SECRETS_SCOPE} 2>/dev/null 
        if databricks secrets put-secret ${SECRETS_SCOPE} DBA_USERNAME --string-value "${DBA_USERNAME}"; then
            echo "failed."
            return 1
        fi
        DBA_USERNAME=$administratorLogin
        export DBA_USERNAME
    fi
}