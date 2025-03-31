#!/usr/bin/env bash

# error out when undeclared variable is used
set -u 

# must be sourced for exports to continue to the next script
if [ "$0" == "$BASH_SOURCE" ]; then
  echo "Script is being executed directly. Please run as source $0"
  exit 1
fi

export AZ_DB_TYPE=zmi

# #############################################################################
# check if sql server if exists
if [[ -z "$DB_HOST" || "$DB_HOST" != *"$-mi" || "$DB_HOST_FQDN" != "$DB_HOST.*" ]] && [[ -z "$AZ_DB_TYPE" || "$AZ_DB_TYPE" == "zmi" ]]; then
    if AZ sql mi list --resource-group "${RG_NAME}"; then
        read_fqdn_dba_if_host     
        set_mi_fqdn_dba_host
        export DB_PORT=3342
    fi
    if [[ -n "$DB_HOST" ]] && [[ -z "$DB_CATALOG" ]] && AZ sql midb list --mi "$DB_HOST" --resource-group "${RG_NAME}"; then
        echo "DB_CATALOG not set. checking az sql db list"
        DB_CATALOG="$(jq -r 'first(.[] | select(.name != "master") | .name)' /tmp/az_stdout.$$)"
        export DB_CATALOG
    else
        DB_CATALOG="$CATALOG_BASENAME"
    fi
    if [[ -n "$DB_HOST" ]]; then
        echo "az sql mi: $DB_HOST $DBA_USERNAME@$DB_HOST_FQDN:$DB_PORT/$DB_CATALOG"
    fi
fi

NINE_CHAR_ID=$(date +%s | xargs printf "%08x\n") # number of seconds since epoch in hex
export NINE_CHAR_ID

# Variable block
export "randomIdentifier=$NINE_CHAR_ID"
export CLOUD_LOCATION="${CLOUD_LOCATION:-westus}"   # "East US" required for Freemium
export resourceGroup="$RG_NAME"
export tag="create-managed-instance"
export vNet="${WHOAMI}-vnet"            #-$randomIdentifier"
export subnet="${WHOAMI}-subnet"        #-$randomIdentifier"
export nsg="${WHOAMI}-nsg"              #-$randomIdentifier"
export route="${WHOAMI}-route"          #-$randomIdentifier"

if [[ -z "$DB_HOST" ]] || [[ "$DB_HOST" != *"-mi" ]]; then DB_HOST="${DB_BASENAME}-mi"; fi  # cannot be underscore
DB_PORT=3342

start_db() {
    AZ sql mi start --mi "$DB_HOST"
}

stop_db() {
    AZ sql mi stop --mi "$DB_HOST"
}

delete_vnet() {
    AZ network vnet delete --name "$vNet"
    AZ network vnet subnet delete --name "$subnet" --resource-group "$resourceGroup" --vnet-name "$vNet"
    AZ network nsg delete --name "$nsg" 
    AZ network route-table delete --name "$route" --resource-group "$resourceGroup"
}


# #############################################################################

echo -e "\nCreating network \n"

if ! AZ network vnet subnet show --name $subnet --vnet-name $vNet; then
    if ! AZ network vnet create --name $vNet --resource-group $resourceGroup --location "$CLOUD_LOCATION" --address-prefixes 10.0.0.0/16; then 
        cat /tmp/az_stderr.$$; return 1 
    fi

    if ! AZ network vnet subnet create --name $subnet --resource-group $resourceGroup --vnet-name $vNet --address-prefixes 10.0.0.0/24 --delegations Microsoft.Sql/managedInstances; then 
        cat /tmp/az_stderr.$$; return 1 
    fi
fi

AZ network nsg rule list --nsg-name $nsg  
if [[ $? != 0 ]]; then
    AZ network nsg create --name $nsg --resource-group $resourceGroup --location "$CLOUD_LOCATION"  
    if [[ $? != 0 ]]; then cat /tmp/az_stderr.$$; return 1; fi

    AZ network nsg rule create --name "allow_management_inbound" --nsg-name $nsg --priority 100 --resource-group $resourceGroup --access Allow --destination-address-prefixes 10.0.0.0/24 --destination-port-ranges 9000 9003 1438 1440 1452 --direction Inbound --protocol Tcp --source-address-prefixes "*" --source-port-ranges "*"  
    if [[ $? != 0 ]]; then cat /tmp/az_stderr.$$; return 1; fi

    AZ network nsg rule create --name "allow_misubnet_inbound" --nsg-name $nsg --priority 200 --resource-group $resourceGroup --access Allow --destination-address-prefixes 10.0.0.0/24 --destination-port-ranges "*" --direction Inbound --protocol "*" --source-address-prefixes 10.0.0.0/24 --source-port-ranges "*"  
    if [[ $? != 0 ]]; then cat /tmp/az_stderr.$$; return 1; fi

    AZ network nsg rule create --name "allow_health_probe_inbound" --nsg-name $nsg --priority 300 --resource-group $resourceGroup --access Allow --destination-address-prefixes 10.0.0.0/24 --destination-port-ranges "*" --direction Inbound --protocol "*" --source-address-prefixes AzureLoadBalancer --source-port-ranges "*"  
    if [[ $? != 0 ]]; then cat /tmp/az_stderr.$$; return 1; fi

    AZ network nsg rule create --name "allow_management_outbound" --nsg-name $nsg --priority 1100 --resource-group $resourceGroup --access Allow --destination-address-prefixes AzureCloud --destination-port-ranges 443 12000 --direction Outbound --protocol Tcp --source-address-prefixes 10.0.0.0/24 --source-port-ranges "*"  
    if [[ $? != 0 ]]; then cat /tmp/az_stderr.$$; return 1; fi

    AZ network nsg rule create --name "allow_misubnet_outbound" --nsg-name $nsg --priority 200 --resource-group $resourceGroup --access Allow --destination-address-prefixes 10.0.0.0/24 --destination-port-ranges "*" --direction Outbound --protocol "*" --source-address-prefixes 10.0.0.0/24 --source-port-ranges "*"  
    if [[ $? != 0 ]]; then cat /tmp/az_stderr.$$; return 1; fi
fi


AZ network route-table route list --route-table-name $route 
if [[ $? != 0 ]]; then
    AZ network route-table create --name $route --resource-group $resourceGroup --location "$CLOUD_LOCATION"  
    if [[ $? != 0 ]]; then cat /tmp/az_stderr.$$; return 1; fi

    AZ network route-table route create --address-prefix 0.0.0.0/0 --name "primaryToMIManagementService" --next-hop-type Internet --resource-group $resourceGroup --route-table-name $route  
    if [[ $? != 0 ]]; then cat /tmp/az_stderr.$$; return 1; fi

    AZ network route-table route create --address-prefix 10.0.0.0/24 --name "ToLocalClusterNode" --next-hop-type VnetLocal --resource-group $resourceGroup --route-table-name $route  
    if [[ $? != 0 ]]; then cat /tmp/az_stderr.$$; return 1; fi

    AZ network vnet subnet update --name $subnet --network-security-group $nsg --route-table $route --vnet-name $vNet --resource-group $resourceGroup  
    if [[ $? != 0 ]]; then cat /tmp/az_stderr.$$; return 1; fi
fi

# #############################################################################

# Freemium plan https://learn.microsoft.com/en-us/azure/azure-sql/managed-instance/free-offer?view=azuresql

echo -e "\nCreating sql managed instance (could take 15 min)\n"

DB_HOST_CREATED=""
if ! AZ sql mi show --name ${DB_HOST}; then
    # This step will take awhile to complete. You can monitor deployment progress in the activity log within the Azure portal.
    # freemium requires --storage 64
    echo -e "AZ sql mi ${DB_HOST}: trying --pricing-model Freemium \n"

    if ! AZ sql mi create --admin-password $DBA_PASSWORD --admin-user $DBA_USERNAME --name $DB_HOST --resource-group $resourceGroup --subnet $subnet --vnet-name $vNet --location "$CLOUD_LOCATION"  -e GeneralPurpose -f Gen5 -c 4 --public-data-endpoint-enabled true --zone-redundant false --pricing-model Freemium --storage 64  --backup-storage-redundancy Local ; then

        echo -e "AZ sql mi ${DB_HOST}: trying paid \n"

        if ! AZ sql mi create --admin-password $DBA_PASSWORD --admin-user $DBA_USERNAME --name $DB_HOST --resource-group $resourceGroup --subnet $subnet --vnet-name $vNet --location "$CLOUD_LOCATION"  -e GeneralPurpose -f Gen5 -c 4 --public-data-endpoint-enabled true --zone-redundant false --storage 64 --backup-storage-redundancy Local ; then
            cat /tmp/az_stderr.$$
            return 1
        fi
    fi
    DB_HOST_CREATED=1
    if [[ -n "$DELETE_DB_AFTER_SLEEP" ]]; then
        sleep "${DELETE_DB_AFTER_SLEEP}" && AZ sql mi delete -y -n "$DB_HOST" -g "${RG_NAME}" >> ~/nohup.out 2>&1 &
    fi
else
    echo "AZ sql mi ${DB_HOST}: exists"
fi

read_fqdn_dba_if_host
set_mi_fqdn_dba_host
if [[ "$(jq -r '.state' /tmp/az_stdout.$$)" != "Ready" ]]; then
    if ! start_db; then
        cat /tmp/az_stderr.$$
        return 1
    fi
fi

AZ configure --defaults managed-instance=$DB_HOST
echo ""

echo "AZ sql mi ${DB_HOST}: https://portal.azure.com/#@${az_tenantDefaultDomain}/resource/subscriptions/${az_id}/resourceGroups/${RG_NAME}/providers/Microsoft.Sql/managedInstances/${DB_HOST}/overview"


# #############################################################################

echo -e "\nCreating catalog\n" 

if ! AZ sql midb show --name ${DB_CATALOG} --mi "${DB_HOST}"; then 
    if ! AZ sql midb create -g $resourceGroup --mi $DB_HOST -n $DB_CATALOG --collation Latin1_General_100_CS_AS_SC; then
        cat /tmp/az_stderr.$$
        return 1
    fi
    if [[ -n "$DELETE_DB_AFTER_SLEEP" ]]; then
        sleep "${DELETE_DB_AFTER_SLEEP}" && AZ sql midb delete -y -n "${DB_CATALOG}" --mi "$DB_HOST" -g "${RG_NAME}" >> ~/nohup.out 2>&1 &
    fi    
else
    echo "AZ sql midb ${DB_CATALOG}: exists"
fi

echo -e "AZ sql midb ${DB_CATALOG}: https://portal.azure.com/#@${az_tenantDefaultDomain}/resource/subscriptions/${az_id}/resourceGroups/${RG_NAME}/providers/Microsoft.Sql/managedInstances/${DB_HOST}/databases/${DB_CATALOG}/overview \n"

# #############################################################################

# Run firewall rules before coming here

echo -e "Creating permissive firewall rules \n"

if ! AZ network nsg rule show --name "0_0_0_0_0" --nsg-name $nsg ; then
    if ! AZ network nsg rule create --name "0_0_0_0_0" --nsg-name $nsg \
        --source-address-prefixes "${DB_FIREWALL_CIDRS[*]}" \
        --priority 151 --access Allow  --source-port-ranges "*" \
        --destination-address-prefixes 10.0.0.0/24 --destination-port-ranges 1433 3342 --direction Inbound --protocol Tcp ; then    
        cat /tmp/az_stderr.$$
        return 1
    fi
fi

echo -e "AZ sql server firewall-rule ${DB_HOST}: https://portal.azure.com/#@${az_tenantDefaultDomain}/resource/subscriptions/${az_id}/resourceGroups/${RG_NAME}/providers/Microsoft.Sql/servers/${DB_HOST}/networking \n"

# #############################################################################
# Check password

echo -e "\nValidate or reset root password.  Could take 5min if resetting\n"

if ! test_db_connect "$DBA_USERNAME" "${DBA_PASSWORD}" "$DB_HOST_FQDN" "$DB_PORT" "master"; then
    if [[ "$DB_HOST_CREATED" ]]; then
        return 1;
    fi
    if ! AZ sql mi update --name ${DB_HOST} --admin-password "${DBA_PASSWORD}" ; then
        cat /tmp/az_stderr.$$
        return 1    
    fi
    if ! test_db_connect "$DBA_USERNAME" "${DBA_PASSWORD}" "$DB_HOST_FQDN" "$DB_PORT" "master"; then
        cat /tmp/az_stderr.$$; return 1;
    fi
fi

# #############################################################################
echo -e "Billing : https://portal.azure.com/#view/Microsoft_Azure_CostManagement/Menu/~/costanalysis \n"
