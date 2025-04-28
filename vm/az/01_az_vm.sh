#!/usr/bin/env bash

set -u 

# #############################################################################
# AZ Cloud

AZ_INIT


if [[ -z $DB_HOST ]]; then
    DB_HOST=$DB_BASENAME
fi

# #############################################################################

# Variable block
export tag="create-managed-instance"
export vNet="${WHOAMI}-vnet"            #-$randomIdentifier"
export subnet="${WHOAMI}-subnet"        #-$randomIdentifier"
export nsg="${WHOAMI}-nsg"              #-$randomIdentifier"
export route="${WHOAMI}-route"          #-$randomIdentifier"

echo -e "\nCreating network if not exists \n"

if ! AZ network vnet subnet show --name $subnet --vnet-name $vNet; then
    if ! AZ network vnet create --name $vNet -g "${RG_NAME}" --location "$CLOUD_LOCATION" --address-prefixes 10.0.0.0/16; then 
        cat /tmp/az_stderr.$$; return 1 
    fi

    if ! AZ network vnet subnet create --name $subnet -g "${RG_NAME}" --vnet-name $vNet --address-prefixes 10.0.0.0/24 --delegations Microsoft.Sql/managedInstances; then 
        cat /tmp/az_stderr.$$; return 1 
    fi
fi

AZ network nsg rule list --nsg-name $nsg  
if [[ $? != 0 ]]; then
    AZ network nsg create --name $nsg -g "${RG_NAME}" --location "$CLOUD_LOCATION"  
    if [[ $? != 0 ]]; then cat /tmp/az_stderr.$$; return 1; fi

    AZ network nsg rule create --name "allow_management_inbound" --nsg-name $nsg --priority 100 -g "${RG_NAME}" --access Allow --destination-address-prefixes 10.0.0.0/24 --destination-port-ranges 9000 9003 1438 1440 1452 --direction Inbound --protocol Tcp --source-address-prefixes "*" --source-port-ranges "*"  
    if [[ $? != 0 ]]; then cat /tmp/az_stderr.$$; return 1; fi

    AZ network nsg rule create --name "allow_misubnet_inbound" --nsg-name $nsg --priority 200 -g "${RG_NAME}" --access Allow --destination-address-prefixes 10.0.0.0/24 --destination-port-ranges "*" --direction Inbound --protocol "*" --source-address-prefixes 10.0.0.0/24 --source-port-ranges "*"  
    if [[ $? != 0 ]]; then cat /tmp/az_stderr.$$; return 1; fi

    AZ network nsg rule create --name "allow_health_probe_inbound" --nsg-name $nsg --priority 300 -g "${RG_NAME}" --access Allow --destination-address-prefixes 10.0.0.0/24 --destination-port-ranges "*" --direction Inbound --protocol "*" --source-address-prefixes AzureLoadBalancer --source-port-ranges "*"  
    if [[ $? != 0 ]]; then cat /tmp/az_stderr.$$; return 1; fi

    AZ network nsg rule create --name "allow_management_outbound" --nsg-name $nsg --priority 1100 -g "${RG_NAME}" --access Allow --destination-address-prefixes AzureCloud --destination-port-ranges 443 12000 --direction Outbound --protocol Tcp --source-address-prefixes 10.0.0.0/24 --source-port-ranges "*"  
    if [[ $? != 0 ]]; then cat /tmp/az_stderr.$$; return 1; fi

    AZ network nsg rule create --name "allow_misubnet_outbound" --nsg-name $nsg --priority 200 -g "${RG_NAME}" --access Allow --destination-address-prefixes 10.0.0.0/24 --destination-port-ranges "*" --direction Outbound --protocol "*" --source-address-prefixes 10.0.0.0/24 --source-port-ranges "*"  
    if [[ $? != 0 ]]; then cat /tmp/az_stderr.$$; return 1; fi
fi


AZ network route-table route list --route-table-name $route 
if [[ $? != 0 ]]; then
    AZ network route-table create --name $route -g "${RG_NAME}" --location "$CLOUD_LOCATION"  
    if [[ $? != 0 ]]; then cat /tmp/az_stderr.$$; return 1; fi

    AZ network route-table route create --address-prefix 0.0.0.0/0 --name "primaryToMIManagementService" --next-hop-type Internet -g "${RG_NAME}" --route-table-name $route  
    if [[ $? != 0 ]]; then cat /tmp/az_stderr.$$; return 1; fi

    AZ network route-table route create --address-prefix 10.0.0.0/24 --name "ToLocalClusterNode" --next-hop-type VnetLocal -g "${RG_NAME}" --route-table-name $route  
    if [[ $? != 0 ]]; then cat /tmp/az_stderr.$$; return 1; fi

    AZ network vnet subnet update --name $subnet --network-security-group $nsg --route-table $route --vnet-name $vNet -g "${RG_NAME}"  
    if [[ $? != 0 ]]; then cat /tmp/az_stderr.$$; return 1; fi
fi

# #############################################################################

# Run firewall rules before coming here

echo -e "Creating permissive firewall rules if not exists \n"

if ! AZ network nsg rule list --nsg-name "$nsg" -g "${RG_NAME}"; then cat /tmp/az_stderr.$$; return 1; fi
if [[ "0" == "$(jq 'map_values(select(.priority==150)) | length' /tmp/az_stdout.$$)" ]]; then
    if ! AZ network nsg rule show --name "0_0_0_0_0" --nsg-name "$nsg" -g "${RG_NAME}"; then
        if ! AZ network nsg rule create --name "0_0_0_0_0" --nsg-name "$nsg" -g "${RG_NAME}"\
            --source-address-prefixes "${DB_FIREWALL_CIDRS[@]}" \
            --priority 151 --access Allow  --source-port-ranges "*" \
            --destination-address-prefixes 10.0.0.0/24 --destination-port-ranges 1433 3342 22 --direction Inbound --protocol Tcp ; then    
            cat /tmp/az_stderr.$$
            return 1
        fi
    fi
fi

# #############################################################################

az vm create \
    --name "$DB_HOST" \
    --resource-group "${RG_NAME}" \
    --location "$CLOUD_LOCATION" \
    --tags "Owner=${DBX_USERNAME}" "${REMOVE_AFTER:+RemoveAfter=${REMOVE_AFTER}}" \
    --image Ubuntu2204 \
    --admin-password "$DBA_PASSWORD" \
    --admin-username "$DBA_USERNAME" \
    --public-ip-sku Standard \
    --nsg $nsg --subnet $subnet --vnet-name $vNet

return 0

# #############################################################################
echo -e "\nBilling ${RG_NAME}: https://portal.azure.com/#@${az_tenantDefaultDomain}/resource/subscriptions/${az_id}/resourceGroups/${RG_NAME}/costanalysis"
echo "Resource list"

az resource list --query "[?resourceGroup=='$RG_NAME'].{ name: name, flavor: kind, resourceType: type, region: location }" --output table
