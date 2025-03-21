#!/usr/bin/env bash

# must be sourced for exports to continue to the next script
if [ "$0" == "$BASH_SOURCE" ]; then
  echo "Script is being executed directly. Please run as source $0"
  exit 1
fi

export AZ_DB_TYPE=zmi

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

NINE_CHAR_ID=$(date +%s | xargs printf "%08x\n") # number of seconds since epoch in hex
export NINE_CHAR_ID

# Variable block
export "randomIdentifier=$NINE_CHAR_ID"
export CLOUD_LOCATION="${CLOUD_LOCATION:-westus}"   # "East US" required for Freemium
export resourceGroup="${WHOAMI}"
export tag="create-managed-instance"
export vNet="${WHOAMI}-vnet"            #-$randomIdentifier"
export subnet="${WHOAMI}-subnet"        #-$randomIdentifier"
export nsg="${WHOAMI}-nsg"              #-$randomIdentifier"
export route="${WHOAMI}-route"          #-$randomIdentifier"

DB_HOST=${DB_HOST:-${DB_BASENAME}-mi}   # cannot be understore
DB_PORT=3342

export az_id=$(az account show | jq -r .id)
export az_tenantDefaultDomain=$(az account show | jq -r .tenantDefaultDomain)

# #############################################################################

az network vnet subnet show --name $subnet --vnet-name $vNet >/tmp/az_stdout.$$ 2>/tmp/az_stderr.$$
if [[ $? != 0 ]]; then
    echo "Creating $vNet with $subnet..."
    az network vnet create --name $vNet --resource-group $resourceGroup --location "$CLOUD_LOCATION" --address-prefixes 10.0.0.0/16 >/tmp/az_stdout.$$ 2>/tmp/az_stderr.$$
    if [[ $? != 0 ]]; then cat /tmp/az_stdout.$$ /tmp/az_stderr.$$; return 0; fi

    az network vnet subnet create --name $subnet --resource-group $resourceGroup --vnet-name $vNet --address-prefixes 10.0.0.0/24 --delegations Microsoft.Sql/managedInstances >/tmp/az_stdout.$$ 2>/tmp/az_stderr.$$
    if [[ $? != 0 ]]; then cat /tmp/az_stdout.$$ /tmp/az_stderr.$$; return 0; fi
else
    echo "Existing $vNet with $subnet..."
fi

 az network nsg rule list --nsg-name $nsg  >/tmp/az_stdout.$$ 2>/tmp/az_stderr.$$
if [[ $? != 0 ]]; then
    echo "Creating $nsg..."
    az network nsg create --name $nsg --resource-group $resourceGroup --location "$CLOUD_LOCATION"  >/tmp/az_stdout.$$ 2>/tmp/az_stderr.$$
    if [[ $? != 0 ]]; then cat /tmp/az_stdout.$$ /tmp/az_stderr.$$; return 0; fi

    az network nsg rule create --name "allow_management_inbound" --nsg-name $nsg --priority 100 --resource-group $resourceGroup --access Allow --destination-address-prefixes 10.0.0.0/24 --destination-port-ranges 9000 9003 1438 1440 1452 --direction Inbound --protocol Tcp --source-address-prefixes "*" --source-port-ranges "*"  >/tmp/az_stdout.$$ 2>/tmp/az_stderr.$$
    if [[ $? != 0 ]]; then cat /tmp/az_stdout.$$ /tmp/az_stderr.$$; return 0; fi

    az network nsg rule create --name "allow_misubnet_inbound" --nsg-name $nsg --priority 200 --resource-group $resourceGroup --access Allow --destination-address-prefixes 10.0.0.0/24 --destination-port-ranges "*" --direction Inbound --protocol "*" --source-address-prefixes 10.0.0.0/24 --source-port-ranges "*"  >/tmp/az_stdout.$$ 2>/tmp/az_stderr.$$
    if [[ $? != 0 ]]; then cat /tmp/az_stdout.$$ /tmp/az_stderr.$$; return 0; fi

    az network nsg rule create --name "allow_health_probe_inbound" --nsg-name $nsg --priority 300 --resource-group $resourceGroup --access Allow --destination-address-prefixes 10.0.0.0/24 --destination-port-ranges "*" --direction Inbound --protocol "*" --source-address-prefixes AzureLoadBalancer --source-port-ranges "*"  >/tmp/az_stdout.$$ 2>/tmp/az_stderr.$$
    if [[ $? != 0 ]]; then cat /tmp/az_stdout.$$ /tmp/az_stderr.$$; return 0; fi

    az network nsg rule create --name "allow_management_outbound" --nsg-name $nsg --priority 1100 --resource-group $resourceGroup --access Allow --destination-address-prefixes AzureCloud --destination-port-ranges 443 12000 --direction Outbound --protocol Tcp --source-address-prefixes 10.0.0.0/24 --source-port-ranges "*"  >/tmp/az_stdout.$$ 2>/tmp/az_stderr.$$
    if [[ $? != 0 ]]; then cat /tmp/az_stdout.$$ /tmp/az_stderr.$$; return 0; fi

    az network nsg rule create --name "allow_misubnet_outbound" --nsg-name $nsg --priority 200 --resource-group $resourceGroup --access Allow --destination-address-prefixes 10.0.0.0/24 --destination-port-ranges "*" --direction Outbound --protocol "*" --source-address-prefixes 10.0.0.0/24 --source-port-ranges "*"  >/tmp/az_stdout.$$ 2>/tmp/az_stderr.$$
    if [[ $? != 0 ]]; then cat /tmp/az_stdout.$$ /tmp/az_stderr.$$; return 0; fi
else
    echo "Existing $nsg..."
fi


az network route-table route list --route-table-name $route >/tmp/az_stdout.$$ 2>/tmp/az_stderr.$$
if [[ $? != 0 ]]; then
    echo "Creating $route..."
    az network route-table create --name $route --resource-group $resourceGroup --location "$CLOUD_LOCATION"  >/tmp/az_stdout.$$ 2>/tmp/az_stderr.$$
    if [[ $? != 0 ]]; then cat /tmp/az_stdout.$$ /tmp/az_stderr.$$; return 0; fi

    az network route-table route create --address-prefix 0.0.0.0/0 --name "primaryToMIManagementService" --next-hop-type Internet --resource-group $resourceGroup --route-table-name $route  >/tmp/az_stdout.$$ 2>/tmp/az_stderr.$$
    if [[ $? != 0 ]]; then cat /tmp/az_stdout.$$ /tmp/az_stderr.$$; return 0; fi

    az network route-table route create --address-prefix 10.0.0.0/24 --name "ToLocalClusterNode" --next-hop-type VnetLocal --resource-group $resourceGroup --route-table-name $route  >/tmp/az_stdout.$$ 2>/tmp/az_stderr.$$
    if [[ $? != 0 ]]; then cat /tmp/az_stdout.$$ /tmp/az_stderr.$$; return 0; fi

    echo "Configuring $subnet with $nsg and $route..."
    az network vnet subnet update --name $subnet --network-security-group $nsg --route-table $route --vnet-name $vNet --resource-group $resourceGroup  >/tmp/az_stdout.$$ 2>/tmp/az_stderr.$$
    if [[ $? != 0 ]]; then cat /tmp/az_stdout.$$ /tmp/az_stderr.$$; return 0; fi
else
    echo "Existing $route..."
fi

# #############################################################################

# Freemium plan https://learn.microsoft.com/en-us/azure/azure-sql/managed-instance/free-offer?view=azuresql

az sql mi show --name ${DB_HOST} >/tmp/az_stdout.$$ 2>/tmp/az_stdout.$$
if [[ $? != 0 ]]; then
    # This step will take awhile to complete. You can monitor deployment progress in the activity log within the Azure portal.
    # freemium requires --storage 64
    echo "az sql mi ${DB_HOST}: trying --pricing-model Freemium"
    az sql mi create --admin-password $DBA_PASSWORD --admin-user $DBA_USERNAME --name $DB_HOST --resource-group $resourceGroup --subnet $subnet --vnet-name $vNet --location "$CLOUD_LOCATION"  -e GeneralPurpose -f Gen5 -c 4 --public-data-endpoint-enabled true --zone-redundant false --pricing-model Freemium --storage 64  --backup-storage-redundancy Local >/tmp/az_sql_mi_create_stdout.$$ 2>/tmp/az_sql_mi_create_stderr.$$
 
    # freemium failed.  create regular 
    if [[ $? != 0 ]]; then
        echo "az sql mi ${DB_HOST}: trying paid"
        az sql mi create --admin-password $DBA_PASSWORD --admin-user $DBA_USERNAME --name $DB_HOST --resource-group $resourceGroup --subnet $subnet --vnet-name $vNet --location "$CLOUD_LOCATION"  -e GeneralPurpose -f Gen5 -c 4 --public-data-endpoint-enabled true --zone-redundant false --storage 64 --backup-storage-redundancy Local >/tmp/az_sql_mi_create_stdout.$$ 2>/tmp/az_sql_mi_create_stderr.$$
    fi
    if [[ $? == 0 ]]; then
        echo "az mi db ${DB_HOST}: created" 
    else
        echo "az mi db ${DB_HOST}: failed."
        cat /tmp/az_sql_mi_create_stdout.$$ /tmp/az_sql_mi_create_stderr.$$
        if [ "$0" == "$BASH_SOURCE" ]; then return 1; else return 1; fi
    fi

else
    echo "az sql mi ${DB_HOST}: exists"
fi

# update password save to secrets
SECRETS_DBA_PASSWORD="$(databricks secrets get-secret ${SECRETS_SCOPE} DBA_PASSWORD 2>/dev/null | jq -r .value | base64 --decode)"
if [[ "$SECRETS_DBA_PASSWORD" != "$DBA_PASSWORD" ]]; then
    echo "az sql mi update --admin-password"
    az sql mi update --admin-password $DBA_PASSWORD --name $DB_HOST --resource-group $resourceGroup --subnet $subnet --vnet-name $vNet >/tmp/az_stdout.$$ 2>/tmp/az_stderr.$$
    if [[ $? == 0 ]]; then
        databricks secrets create-scope ${SECRETS_SCOPE} 2>/dev/null 
        databricks secrets put-secret ${SECRETS_SCOPE} DBA_PASSWORD --string-value "${DBA_PASSWORD}"
        databricks secrets put-secret ${SECRETS_SCOPE} DBA_USERNAME --string-value "${DBA_USERNAME}"
    else
        echo "az sql mi update --admin-password failed"
        if [ "$0" == "$BASH_SOURCE" ]; then return 1; else return 1; fi
    fi
fi

export DB_HOST_FQDN=$(cat /tmp/az_stdout.$$ | jq -r .fullyQualifiedDomainName | sed "s/^${DB_HOST}\./${DB_HOST}\.public\./g")

echo "az sql mi ${DB_HOST}: https://portal.azure.com/#@${az_tenantDefaultDomain}/resource/subscriptions/${az_id}/resourceGroups/${WHOAMI}/providers/Microsoft.Sql/managedInstances/${DB_HOST}/overview"

az configure --defaults managed-instance=$DB_HOST
echo ""

# #############################################################################

az sql midb show --name ${DB_CATALOG} --managed-instance "${DB_HOST}" --output table >/tmp/az_stdout.$$ 2>/tmp/az_stderr.$$
if [[ $? != 0 ]]; then
    az sql midb create -g $resourceGroup --mi $DB_HOST -n $DB_CATALOG --collation Latin1_General_100_CS_AS_SC

    az configure --defaults managed-instance=$DB_HOST
    if [[ $? == 0 ]]; then
        echo "az sql midb ${DB_CATALOG}: created" 
    else
        echo "az sql midb ${DB_CATALOG}: failed."
        cat /tmp/az_sql_mi_create_stdout.$$ /tmp/az_sql_mi_create_stderr.$$
        if [ "$0" == "$BASH_SOURCE" ]; then return 1; else return 1; fi
    fi
else
    echo "az sql midb ${DB_CATALOG}: exists"
fi

echo "az sql midb ${DB_CATALOG}: https://portal.azure.com/#@${az_tenantDefaultDomain}/resource/subscriptions/${az_id}/resourceGroups/${WHOAMI}/providers/Microsoft.Sql/managedInstances/${DB_HOST}/databases/${DB_CATALOG}/overview"
echo ""

start_db() {
    az sql mi start --mi $DB_HOST
}

stop_db() {
    az sql mi stop --mi $DB_HOST
}

delete_vnet() {
    az network vnet delete --name $vNet
    az network vnet subnet delete --name $subnet --resource-group $resourceGroup --vnet-name $vNet
    az network nsg delete --name $nsg 
    az network route-table delete --name $route --resource-group $resourceGroup
}

# #############################################################################

# Run firewall rules before coming here
az network nsg rule show --name "allow_dbx_inbound" --nsg-name $nsg >/tmp/az_stdout.$$ 2>/tmp/az_stderr.$$
if [[ $? != 0 ]]; then
    echo "az network nsg rule create --name "allow_dbx_inbound" --nsg-name $nsg: MAKE SURE TO CONFIGURE FIREWALL RULES"
else
    echo "az network nsg rule --name "allow_dbx_inbound" --nsg-name $nsg: exists"
fi

echo "az sql server firewall-rule ${DB_HOST}: https://portal.azure.com/#@${az_tenantDefaultDomain}/resource/subscriptions/${az_id}/resourceGroups/${WHOAMI}/providers/Microsoft.Network/networkSecurityGroups/${nsg}/overview"
echo ""

# #############################################################################
echo "Billing : https://portal.azure.com/#view/Microsoft_Azure_CostManagement/Menu/~/costanalysis"
echo ""
