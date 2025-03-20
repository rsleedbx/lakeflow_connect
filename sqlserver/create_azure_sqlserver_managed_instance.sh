#!/usr/bin/env bash

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
 source <(curl -s -L https://raw.githubusercontent.com/rsleedbx/lakeflow_connect/refs/heads/sqlserver/sqlserver/create_azure_sqlserver_01.sh)
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
export instance="${WHOAMI}-instance"    #-$randomIdentifier"
export login=$DBA_USERNAME
export password=$DBA_PASSWORD
export dbname=${DB_HOST}_mi


# #############################################################################

echo "Creating $vNet with $subnet..."
az network vnet create --name $vNet --resource-group $resourceGroup --location "$CLOUD_LOCATION" --address-prefixes 10.0.0.0/16
az network vnet subnet create --name $subnet --resource-group $resourceGroup --vnet-name $vNet --address-prefixes 10.0.0.0/24 --delegations Microsoft.Sql/managedInstances

echo "Creating $nsg..."
az network nsg create --name $nsg --resource-group $resourceGroup --location "$CLOUD_LOCATION"

az network nsg rule create --name "allow_management_inbound" --nsg-name $nsg --priority 100 --resource-group $resourceGroup --access Allow --destination-address-prefixes 10.0.0.0/24 --destination-port-ranges 9000 9003 1438 1440 1452 --direction Inbound --protocol Tcp --source-address-prefixes "*" --source-port-ranges "*"
az network nsg rule create --name "allow_misubnet_inbound" --nsg-name $nsg --priority 200 --resource-group $resourceGroup --access Allow --destination-address-prefixes 10.0.0.0/24 --destination-port-ranges "*" --direction Inbound --protocol "*" --source-address-prefixes 10.0.0.0/24 --source-port-ranges "*"
az network nsg rule create --name "allow_health_probe_inbound" --nsg-name $nsg --priority 300 --resource-group $resourceGroup --access Allow --destination-address-prefixes 10.0.0.0/24 --destination-port-ranges "*" --direction Inbound --protocol "*" --source-address-prefixes AzureLoadBalancer --source-port-ranges "*"
az network nsg rule create --name "allow_management_outbound" --nsg-name $nsg --priority 1100 --resource-group $resourceGroup --access Allow --destination-address-prefixes AzureCloud --destination-port-ranges 443 12000 --direction Outbound --protocol Tcp --source-address-prefixes 10.0.0.0/24 --source-port-ranges "*"
az network nsg rule create --name "allow_misubnet_outbound" --nsg-name $nsg --priority 200 --resource-group $resourceGroup --access Allow --destination-address-prefixes 10.0.0.0/24 --destination-port-ranges "*" --direction Outbound --protocol "*" --source-address-prefixes 10.0.0.0/24 --source-port-ranges "*"

echo "Creating $route..."
az network route-table create --name $route --resource-group $resourceGroup --location "$CLOUD_LOCATION"

az network route-table route create --address-prefix 0.0.0.0/0 --name "primaryToMIManagementService" --next-hop-type Internet --resource-group $resourceGroup --route-table-name $route
az network route-table route create --address-prefix 10.0.0.0/24 --name "ToLocalClusterNode" --next-hop-type VnetLocal --resource-group $resourceGroup --route-table-name $route

echo "Configuring $subnet with $nsg and $route..."
az network vnet subnet update --name $subnet --network-security-group $nsg --route-table $route --vnet-name $vNet --resource-group $resourceGroup



# Freemium plan https://learn.microsoft.com/en-us/azure/azure-sql/managed-instance/free-offer?view=azuresql

# This step will take awhile to complete. You can monitor deployment progress in the activity log within the Azure portal.
# freemium requires --storage 64
echo "Creating $instance with $vNet and $subnet..."
az sql mi create --admin-password $password --admin-user $login --name $instance --resource-group $resourceGroup --subnet $subnet --vnet-name $vNet --location "$CLOUD_LOCATION"  -e GeneralPurpose -f Gen5 -c 4 --public-data-endpoint-enabled true --zone-redundant false --pricing-model Freemium --storage 64 --zone-redundant false
 
# freemium failed.  create regular 
if [[ $? != 0 ]]; then
    az sql mi create --admin-password $password --admin-user $login --name $instance --resource-group $resourceGroup --subnet $subnet --vnet-name $vNet --location "$CLOUD_LOCATION"  -e GeneralPurpose -f Gen5 -c 4 --public-data-endpoint-enabled true --zone-redundant false --storage 64 --zone-redundant false
fi

az sql midb create -g $resourceGroup --mi $instance -n $dbname --collation Latin1_General_100_CS_AS_SC

az configure --defaults managed-instance=$instance

az sql midb stop -g $resourceGroup --mi $instance -n $dbname

az configure --defaults managed-instance=$instance


az sql midb list --managed-instance=$instance 
az sql midb show -name=$instance 

export instance_fqdn

sqlcmd -S $instance_fqdn -U $DBA_USERNAME -P $DBA_PASSWORD -C

az sql mi stop --mi $instance


# 

az network vnet delete --name $vNet
az network vnet subnet delete --name $subnet --resource-group $resourceGroup --vnet-name $vNet
az network nsg delete --name $nsg 
az network route-table delete --name $route --resource-group $resourceGroup