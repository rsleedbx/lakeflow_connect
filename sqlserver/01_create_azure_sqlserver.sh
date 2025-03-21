#!/usr/bin/env bash

# must be sourced for exports to continue to the next script
if [ "$0" == "$BASH_SOURCE" ]; then
  echo "Script is being executed directly. Please run as source $0"
  exit 1
fi

export REMOVE_AFTER=$(date --date='+0 day' +%Y-%m-%d)

export CLOUD_LOCATION="${CLOUD_LOCATION:-"East US"}"
export WHOAMI=${WHOAMI:-$(whoami | tr -d .)}

export DBX_USERNAME=${DBX_USERNAME:-$(databricks current-user me | jq -r .userName)}
export DB_CATALOG=${DB_CATALOG:-${WHOAMI}}
export DB_SCHEMA=${DB_SCHEMA:-${WHOAMI}}
export DB_PORT=${DB_PORT:-1433}

export DBA_USERNAME=${DBA_USERNAME:-sqlserver}    # GCP defaults to sqlserver.  Make it same for Azure
export USER_USERNAME=${USER_USERNAME:-${WHOAMI}}  # set if not defined

# set or use existing DB_HOST and DB_HOST_FQDN (dns or IP)
export DB_HOST=$(az sql server list --output json 2>/dev/null | jq -r .[].name)
if [[ -z $DB_HOST ]]; then 
  export DB_HOST=${DB_HOST:-$(pwgen -1AB 8)}        # lower case, name seen on internet
fi
export DB_HOST_FQDN=$(az sql server show --name $DB_HOST 2>/dev/null | jq -r .fullyQualifiedDomainName)
if [[ -n "${DB_HOST_FQDN}" ]]; then echo "DB_HOST: $DB_HOST"; fi

export SECRETS_SCOPE="${WHOAMI}_${DB_HOST}"

# set or use existing DBA_PASSWORD
export DBA_PASSWORD="$(databricks secrets get-secret ${SECRETS_SCOPE} DBA_PASSWORD 2>/dev/null | jq -r .value | base64 --decode)"
DBA_PASSWORD_RESET=""
if [[ -z "$DBA_PASSWORD" ]]; then 
    export DBA_PASSWORD="${DBA_PASSWORD:-$(pwgen -1y 32)}"  # set if not defined
    if [[ -n $DB_HOST_FQDN ]]; then 
        export DBA_PASSWORD_RESET=1; 
        databricks secrets create-scope ${SECRETS_SCOPE} 2>/dev/null 
        databricks secrets put-secret ${SECRETS_SCOPE} DBA_PASSWORD --string-value "${DBA_PASSWORD}"
    fi
fi

# set or use existing USER_PASSWORD
export USER_PASSWORD=$(databricks secrets get-secret ${SECRETS_SCOPE} USER_PASSWORD 2>/dev/null | jq -r .value | base64 --decode)
USER_PASSWORD_RESET=""
if [[ -z $USER_PASSWORD ]]; then 
    export USER_PASSWORD=${USER_PASSWORD:-$(pwgen -1y 32)}  # set if not defined
    if [[ -n $DB_HOST_FQDN ]]; then 
        export USER_PASSWORD_RESET=1
        databricks secrets create-scope ${SECRETS_SCOPE} 2>/dev/null  
        databricks secrets put-secret ${SECRETS_SCOPE} USER_PASSWORD --string-value "${USER_PASSWORD}"
    fi
fi  

# DBA password reset on the master if the current password not work
if [[ -n "$DB_HOST_FQDN" ]] && [[ -z "$(echo "select 1" | sqlcmd -S $DB_HOST_FQDN,${DB_PORT} -U $DBA_USERNAME -P $DBA_PASSWORD -C -l 60)" ]]; then 
    az_sql_server_update_output="$(az sql server update --name ${DB_HOST} --admin-password "${DBA_PASSWORD}")"
    sqlcmd_select1_output="$(echo "select 1" | sqlcmd -S $DB_HOST_FQDN,${DB_PORT} -U $DBA_USERNAME -P $DBA_PASSWORD -C -l 60)"
    export sqlcmd_select1_output
    if [[ -n "$sqlcmd_select1_output" ]]; then
    echo "$DB_HOST: DBA_PASSWORD_RESET with $DBA_PASSWORD"
    else
        echo "Error: DBA_PASSWORD_RESET failed $DBA_PASSWORD"
    fi
fi

# user password reset on the master if the current password not work
if [[ -n "$DB_HOST_FQDN" ]] && [[ -z "$(echo "select 1" | sqlcmd -S $DB_HOST_FQDN,${DB_PORT} -U $USER_USERNAME -P $USER_PASSWORD -C -l 60)" ]]; then 
    cat <<EOF | sqlcmd -S ${DB_HOST_FQDN},${DB_PORT} -U "${DBA_USERNAME}" -P "${DBA_PASSWORD}" -C -l 60
    CREATE LOGIN ${USER_USERNAME} WITH PASSWORD = '${USER_PASSWORD}'
    go
    alter login ${USER_USERNAME} with password = '${USER_PASSWORD}'
    go
    -- gcp does not allow user login
    CREATE USER ${USER_USERNAME} FOR LOGIN ${USER_USERNAME} WITH DEFAULT_SCHEMA=dbo
    go
EOF
    sqlcmd_select1_output="$(echo "select 1" | sqlcmd -S $DB_HOST_FQDN,${DB_PORT} -U $USER_USERNAME -P $USER_PASSWORD -C -l 60)"
    export sqlcmd_select1_output
    if [[ -n "$sqlcmd_select1_output" ]]; then
    echo "$DB_HOST: USER_PASSWORD_RESET with $USER_PASSWORD"
    else
        echo "Error: USER_PASSWORD_RESET failed $USER_PASSWORD"
    fi
fi

# #############################################################################

export az_id=$(az account show | jq -r .id)
export az_tenantDefaultDomain=$(az account show | jq -r .tenantDefaultDomain)

if [[ -n "${CLOUD_LOCATION}" ]]; then 
    az configure --defaults location="${CLOUD_LOCATION}"
fi

# #############################################################################
# https://learn.microsoft.com/en-us/azure/azure-resource-manager/management/manage-resource-groups-cli

# multiples tags are defined correctly below.  NOT A MISTAKE
az_group_show_output="$(az group show --resource-group "${WHOAMI}" --output table 2>/dev/null)"
export az_group_show_output

if [[ -z "$az_group_show_output" ]]; then
    az_group_create_output=$(az group create --resource-group "${WHOAMI}" --tags "Owner=${DBX_USERNAME}" "${REMOVE_AFTER:+RemoveAfter=${REMOVE_AFTER}}")
    export az_group_create_output
    echo "az group ${WHOAMI}: created"
else
    echo "az group ${WHOAMI}: exists"
fi
az configure --defaults group="${WHOAMI}"

az_group_show_output=$(az group show --resource-group "${WHOAMI}" --output table)

echo "az group ${WHOAMI}: https://portal.azure.com/#@${az_tenantDefaultDomain}/resource/subscriptions/${az_id}/resourceGroups/${WHOAMI}/overview"
echo ""

# #############################################################################

az_sql_server_list_output="$(az sql server list --output table 2>/dev/null)"
export az_sql_server_list_output

if [[ -z "${az_sql_server_list_output}" ]]; then
# name cannot have underscore
    az_sql_server_create_output=$(az sql server create --name ${DB_HOST} \
    --admin-user "${DBA_USERNAME}" \
    --admin-password "${DBA_PASSWORD}"
    )
    echo "az sql ${DB_HOST}: created"
else
    echo "az sql ${DB_HOST}: exists"
fi
export az_sql_server_create_output

# change the DBA password for case where server was already created
az_sql_server_update_output=$(az sql server update --name ${DB_HOST} --admin-password "${DBA_PASSWORD}")
export az_sql_server_update_output

# save to secrets
databricks secrets create-scope ${SECRETS_SCOPE} 2>/dev/null 
databricks secrets put-secret ${SECRETS_SCOPE} DBA_PASSWORD --string-value "${DBA_PASSWORD}"
databricks secrets put-secret ${SECRETS_SCOPE} DBA_USERNAME --string-value "${DBA_USERNAME}"

export DB_HOST_FQDN=$(az sql server show --name $DB_HOST | jq -r .fullyQualifiedDomainName)
az_sql_server_list_output="$(az sql server list --output table)"
az configure --defaults sql-server=${DB_HOST}

echo "az sql ${DB_HOST}: https://portal.azure.com/#@${az_tenantDefaultDomain}/resource/subscriptions/${az_id}/resourceGroups/${WHOAMI}/providers/Microsoft.Sql/servers/${DB_HOST}/overview"
echo ""

# #############################################################################

az_sql_db_list_output=$(az sql db show --name ${DB_CATALOG} --output table 2>/dev/null)
export az_sql_db_list_output

if [[ -z "${az_sql_db_list_output}" ]]; then
    # try free first
    echo "az sql db ${DB_CATALOG}: trying --use-free-limit"
    az_sql_db_create_output=$(az sql db create --name "${DB_CATALOG}" -e GeneralPurpose -f Gen5 -c 1 \
    --compute-model Serverless --backup-storage-redundancy Local \
    --zone-redundant false --exhaustion-behavior AutoPause --use-free-limit 2>/dev/null 
    )
    # if not free, then use paid plan
    if [[ $? != 0 ]]; then
        echo "az sql db ${DB_CATALOG}: trying paid plan"
        az_sql_db_create_output=$(az sql db create --name "${DB_CATALOG}" -e GeneralPurpose -f Gen5 -c 1 \
        --compute-model Serverless --backup-storage-redundancy Local \
        --zone-redundant false --exhaustion-behavior AutoPause --auto-pause-delay 15
        )
    fi 
    echo "az sql db ${DB_CATALOG}: created"
else
    echo "az sql db ${DB_CATALOG}: exists"
fi
export az_sql_db_create_output

az_sql_db_list_output=$(az sql db list --output table)

echo "az sql db ${DB_CATALOG}: https://portal.azure.com/#@${az_tenantDefaultDomain}/resource/subscriptions/${az_id}/resourceGroups/${WHOAMI}/providers/Microsoft.Sql/servers/${DB_HOST}/databases/${DB_CATALOG}/overview"
echo ""

# #############################################################################

# Run firewall rules before coming here
az_sql_server_firewall_rules_output="$(az sql server firewall-rule list)"
export az_sql_server_firewall_rules_output

if [[ -z "${az_sql_server_firewall_rules_output}" ]]; then
    echo "az sql server firewall-rule ${DB_HOST}: MAKE SURE TO CONFIGURE FIREWALL RULES"
else
    echo "az sql server firewall-rule ${DB_HOST}: exists"
fi

echo "az sql server firewall-rule ${DB_HOST}: https://portal.azure.com/#@${az_tenantDefaultDomain}/resource/subscriptions/${az_id}/resourceGroups/${WHOAMI}/providers/Microsoft.Sql/servers/${DB_HOST}/networking"
echo ""

# #############################################################################
echo "Billing : https://portal.azure.com/#view/Microsoft_Azure_CostManagement/Menu/~/costanalysis"
echo ""


stop_db() {
    echo "stop db not required"
}
export -f stop_db

delete_db() {
    echo "az sql ${DB_HOST}: delete started"
    az sql server delete --name "${DB_HOST}"
    echo "az sql ${DB_HOST}: delete completed"
}
export -f delete_db
