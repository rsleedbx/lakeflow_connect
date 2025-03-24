#!/usr/bin/env bash

# must be sourced for exports to continue to the next script
if [ "$0" == "$BASH_SOURCE" ]; then
  echo "Script is being executed directly. Please run as source $0"
  exit 1
fi

export AZ_DB_TYPE=zsql

if [[ -z $DBX_USERNAME ]] || \
 [[ -z $WHOAMI ]] || \
 [[ -z $EXPIRE_DATE ]] || \
 [[ -z $DB_CATALOG ]] || \
 [[ -z $DB_SCHEMA ]] || \
 [[ -z $DB_HOST ]] || \
 [[ -z $DB_PORT ]] || \
 [[ -z $DBA_PASSWORD ]] || \
 [[ -z $USER_PASSWORD ]] || \
 [[ -z $DBA_USERNAME ]] || \
 [[ -z $USER_USERNAME ]] || \
 [[ -z $DB_HOST ]] || \
 [[ -z $DB_HOST_FQDN ]]; then 
    if [[ -f ./00_lakeflow_connect_env.sh ]]; then
        source ./00_lakeflow_connect_env.sh
    else
        source <(curl -s -L https://raw.githubusercontent.com/rsleedbx/lakeflow_connect/refs/heads/sqlserver/sqlserver/00_lakeflow_connect_env.sh)
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

# update password save to secrets
SECRETS_DBA_PASSWORD="$(databricks secrets get-secret ${SECRETS_SCOPE} DBA_PASSWORD 2>/dev/null | jq -r .value | base64 --decode)"
if [[ "$SECRETS_DBA_PASSWORD" != "$DBA_PASSWORD" ]]; then
    # change the DBA password for case where server was already created
    echo "az sql server update --name ${DB_HOST} --admin-password"
    az sql server update --name ${DB_HOST} --admin-password "${DBA_PASSWORD}" >/tmp/az_stdout.$$ 2>/tmp/az_stderr.$$
    if [[ $? == 0 ]]; then
        databricks secrets create-scope ${SECRETS_SCOPE} 2>/dev/null 
        databricks secrets put-secret ${SECRETS_SCOPE} DBA_PASSWORD --string-value "${DBA_PASSWORD}"
        databricks secrets put-secret ${SECRETS_SCOPE} DBA_USERNAME --string-value "${DBA_USERNAME}"
    else
        echo "az sql server update --name ${DB_HOST} failed"
        if [ "$0" == "$BASH_SOURCE" ]; then return 1; else return 1; fi
    fi
fi

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
