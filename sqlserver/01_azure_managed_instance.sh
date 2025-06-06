#!/usr/bin/env bash

# error out when undeclared variable is used
set -u 

# must be sourced for exports to continue to the next script
if [ "$0" == "$BASH_SOURCE" ]; then
  echo "Script is being executed directly. Please run as source $0"
  exit 1
fi

export AZ_DB_TYPE=mi
export AZ_DB_SUFFIX=mi
export CONNECTION_TYPE=SQLSERVER
export SOURCE_TYPE=$CONNECTION_TYPE

# reset to auto if SECRETS_SCOPE does not have right suffix
if [[ "${WHOAMI}" == "lfcddemo" ]] && [[ -z "${CONNECTION_NAME}" || "${CONNECTION_NAME}" != *"-${AZ_DB_TYPE}" ]]; then
    CONNECTION_NAME="${WHOAMI}-${AZ_DB_TYPE}"
    echo -e "\nChanging the connection nam\n"
    echo -e "CONNECTION_NAME=$CONNECTION_NAME"
fi

# #############################################################################
# export functions

SQLCLI() {
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

    echo sqlcmd "${DB_USERNAME}:/${DB_CATALOG}" "${PWMASK}" 

    if [[ -t 0 ]]; then
        # stdin is attached
        sqlcmd -d "$DB_CATALOG" -S "${DB_HOST_FQDN},${DB_PORT}" -U "${DBA_USERNAME}" -P "${DBA_PASSWORD}" -C -l "${DB_LOGIN_TIMEOUT}" "${@}"
    else
        # running in batch mode
        sqlcmd -d "$DB_CATALOG" -S "${DB_HOST_FQDN},${DB_PORT}" -U "${DBA_USERNAME}" -P "${DBA_PASSWORD}" -C -l "${DB_LOGIN_TIMEOUT}" -h -1 "${@}" >${DB_STDOUT} 2>${DB_STDERR} 
    fi
    RC=$?
    if [[ "$RC" != "0" && "PRINT_RETURN" == "$DB_EXIT_ON_ERROR" ]]; then
        cat "${DB_STDOUT}" "${DB_STDERR}"
        return $RC
    elif [[ "$RC" != "0" && "PRINT_EXIT" == "$DB_EXIT_ON_ERROR" ]]; then 
        cat "${DB_STDOUT}" "${DB_STDERR}"
        kill -INT $$
    elif [[ "$RC" == "0" && "RETURN_1_STDOUT_EMPTY" == "$DB_EXIT_ON_ERROR" ]]; then 
        if [[ ! -s "${DB_STDOUT}" ]]; then 
            return 1
        else
            return 0
        fi
    else
        return $RC
    fi
}
export -f SQLCLI

SQLCLI_DBA() {
    DB_USERNAME="${DBA_USERNAME}" DB_PASSWORD="${DBA_PASSWORD}" DB_CATALOG="" SQLCLI "${@}"
}
export -f SQLCLI_DBA

SQLCLI_USER() {
    DB_USERNAME="${USER_USERNAME}" DB_PASSWORD="${USER_PASSWORD}" SQLCLI "${@}"
}
export -f SQLCLI_USER


# #############################################################################
# AZ Cloud

AZ_INIT


# #############################################################################
# check if sql server if exists

echo -e "\nLoading available host and catalog if not specified \n"

# make host name follow the naming convention
if [[ -n "$DB_HOST" && "$DB_HOST" != *"-${AZ_DB_SUFFIX}" ]]; then
    DB_HOST=""
    DB_HOST_FQDN=""
fi

if [[ -z "$DB_HOST" || "$DB_HOST_FQDN" != "$DB_HOST.public."* ]] && \
    [[ -z "$AZ_DB_TYPE" || "$AZ_DB_TYPE" == "zmi" ]] && \
    AZ sql mi list -g "${RG_NAME}"; then

    read -rd "\n" x1 x2 x3 <<< "$(jq -r 'first(.[] | select(.fullyQualifiedDomainName!=null and .type=="Microsoft.Sql/managedInstances" and .provisioningState!="Deleting")) | .name, .fullyQualifiedDomainName, .administratorLogin' /tmp/az_stdout.$$)"
    if [[ -n $x1 && -n $x2 && -n $x3 ]]; then 
        DB_HOST="$x1"; DB_HOST_FQDN="$x2"; DBA_USERNAME="$x3"; 
        set_mi_fqdn_dba_host
    fi
fi

# get avail catalog if not specified
if [[ -n "$DB_HOST" ]] && [[ -z "$DB_CATALOG" || "$DB_CATALOG" == "$CATALOG_BASENAME" ]] && \
    AZ sql midb list --mi "$DB_HOST" -g "${RG_NAME}"; then

    x1=""
    # check if secrets exists for this host
    if get_secrets $DB_HOST; then
        # reuse catalog from the secret if exists?
        x1="$(jq -r --arg DB_CATALOG $DB_CATALOG 'first(.[] | select(.name == $DB_CATALOG) | .name)' /tmp/az_stdout.$$)"
    fi

    if [[ -z $x1 ]]; then
        echo "DB_CATALOG not set. checking az sql db list"
        x1="$(jq -r 'first(.[] | select(.name != "master") | .name)' /tmp/az_stdout.$$)"
    fi
    if [[ -n $x1 ]]; then DB_CATALOG="$x1"; fi
fi

NINE_CHAR_ID=$(date +%s | xargs printf "%08x\n") # number of seconds since epoch in hex
export NINE_CHAR_ID

# Variable block
export "randomIdentifier=$NINE_CHAR_ID"
export tag="create-managed-instance"
export vNet="${WHOAMI}-vnet"            #-$randomIdentifier"
export subnet="${WHOAMI}-subnet"        #-$randomIdentifier"
export nsg="${WHOAMI}-nsg"              #-$randomIdentifier"
export route="${WHOAMI}-route"          #-$randomIdentifier"

# secrets was empty or invalid.
if [[ -z "${DBA_USERNAME}" || -z "${DB_CATALOG}" || -z "$DB_HOST" || "$DB_HOST" != *"-${AZ_DB_SUFFIX}" ]]; then 
    DB_HOST="${DB_BASENAME}-${AZ_DB_SUFFIX}"; 
    DB_CATALOG="$CATALOG_BASENAME"
fi  

DB_PORT=3342

start_db() {
    AZ sql mi start --mi "$DB_HOST"
}

stop_db() {
    AZ sql mi stop --mi "$DB_HOST"
}

delete_vnet() {
    AZ network vnet delete --name "$vNet"
    AZ network vnet subnet delete --name "$subnet" -g "${RG_NAME}" --vnet-name "$vNet"
    AZ network nsg delete --name "$nsg" 
    AZ network route-table delete --name "$route" -g "${RG_NAME}"
}


# #############################################################################

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

# Freemium plan https://learn.microsoft.com/en-us/azure/azure-sql/managed-instance/free-offer?view=azuresql

echo -e "\nCreating sql managed instance if not exists(could take 15 min)\n"

DB_HOST_CREATED=""
if ! AZ sql mi show --name "${DB_HOST}"; then
    # This step will take awhile to complete. You can monitor deployment progress in the activity log within the Azure portal.
    # freemium requires --storage 64
    echo -e "AZ sql mi ${DB_HOST}: trying --pricing-model Freemium \n"

    if ! AZ sql mi create --admin-password $DBA_PASSWORD --admin-user $DBA_USERNAME --name $DB_HOST -g "${RG_NAME}" \
        --tags "Owner=${DBX_USERNAME}" "${REMOVE_AFTER:+RemoveAfter=${REMOVE_AFTER}}" \
        --subnet $subnet --vnet-name $vNet --location "$CLOUD_LOCATION"  -e GeneralPurpose -f Gen5 -c 4 \
        --public-data-endpoint-enabled true --zone-redundant false --pricing-model Freemium \
        --storage 64  --backup-storage-redundancy Local ; then

        # delete any leftover
        cat /tmp/az_stderr.$$
        AZ sql mi delete -y --name $DB_HOST -g "${RG_NAME}"

        # try paid
        echo -e "AZ sql mi ${DB_HOST}: trying paid \n"

        if ! AZ sql mi create --admin-password $DBA_PASSWORD --admin-user $DBA_USERNAME --name $DB_HOST -g "${RG_NAME}" \
        --tags "Owner=${DBX_USERNAME}" "${REMOVE_AFTER:+RemoveAfter=${REMOVE_AFTER}}" \
        --subnet $subnet --vnet-name $vNet --location "$CLOUD_LOCATION"  -e GeneralPurpose -f Gen5 -c 4 \
        --public-data-endpoint-enabled true --zone-redundant false \
        --storage 64 --backup-storage-redundancy Local ; then
            cat /tmp/az_stderr.$$
            return 1
        fi
    fi
    DB_HOST_CREATED=1
    if [[ -n "$DELETE_DB_AFTER_SLEEP" ]]; then
        nohup sleep "${DELETE_DB_AFTER_SLEEP}" && AZ sql mi delete -y -n "$DB_HOST" -g "${RG_NAME}" </dev/null >> ~/nohup.out 2>&1 &
        echo -e "\nDeleting managed instance ${DB_HOST} after ${DELETE_DB_AFTER_SLEEP}.  To cancel kill -9 $! \n" 
    fi
else
    read -rd "\n" x1 x2 <<< "$(jq -r 'select(.type == "Microsoft.Sql/managedInstances") | .name, .administratorLogin' /tmp/az_stdout.$$)"
    if [[ -z $x1 || -z $x2 ]]; then 
        echo "$DB_HOST is not a Microsoft.Sql/managedInstances"
        return 1
    fi
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

AZ configure --defaults managed-instance="$DB_HOST"
echo ""

echo "AZ sql mi ${DB_HOST}: https://portal.azure.com/#@${az_tenantDefaultDomain}/resource/subscriptions/${az_id}/resourceGroups/${RG_NAME}/providers/Microsoft.Sql/managedInstances/${DB_HOST}/overview"


# #############################################################################

echo -e "\nCreating catalog if not exists\n" 

if ! AZ sql midb show -n "${DB_CATALOG}" --mi "${DB_HOST}" -g "${RG_NAME}"; then 
    if ! AZ sql midb create -n "${DB_CATALOG}" --mi "${DB_HOST}" -g "${RG_NAME}" \
        --tags "Owner=${DBX_USERNAME}" "${REMOVE_AFTER:+RemoveAfter=${REMOVE_AFTER}}" \
        --collation Latin1_General_100_CS_AS_SC; then
        cat /tmp/az_stderr.$$
        return 1
    fi
    if [[ -n "$DELETE_DB_AFTER_SLEEP" ]]; then
        nohup sleep "${DELETE_DB_AFTER_SLEEP}" && AZ sql midb delete -y -n "${DB_CATALOG}" --mi "$DB_HOST" -g "${RG_NAME}" </dev/null >> ~/nohup.out 2>&1 &
        echo -e "\nDeleting catalog ${DB_CATALOG} after ${DELETE_DB_AFTER_SLEEP}.  To cancel kill -9 $! \n" 
    fi    
else
    echo "AZ sql midb ${DB_CATALOG}: exists"
fi

echo -e "AZ sql midb ${DB_CATALOG}: https://portal.azure.com/#@${az_tenantDefaultDomain}/resource/subscriptions/${az_id}/resourceGroups/${RG_NAME}/providers/Microsoft.Sql/managedInstances/${DB_HOST}/databases/${DB_CATALOG}/overview \n"

# #############################################################################

# Run firewall rules before coming here

echo -e "Creating permissive firewall rules if not exists \n"

if ! AZ network nsg rule list --nsg-name "$nsg" -g "${RG_NAME}"; then cat /tmp/az_stderr.$$; return 1; fi
if [[ "0" == "$(jq 'map_values(select(.priority==150)) | length' /tmp/az_stdout.$$)" ]]; then
    if ! AZ network nsg rule show --name "0_0_0_0_0" --nsg-name "$nsg" -g "${RG_NAME}"; then
        if ! AZ network nsg rule create --name "0_0_0_0_0" --nsg-name "$nsg" -g "${RG_NAME}"\
            --source-address-prefixes "${DB_FIREWALL_CIDRS[@]}" \
            --priority 151 --access Allow  --source-port-ranges "*" \
            --destination-address-prefixes 10.0.0.0/24 --destination-port-ranges 1433 3342 --direction Inbound --protocol Tcp ; then    
            cat /tmp/az_stderr.$$
            return 1
        fi
    fi
fi

echo -e "AZ sql server firewall-rule ${DB_HOST}: https://portal.azure.com/#@${az_tenantDefaultDomain}/resource/subscriptions/${az_id}/resourceGroups/${RG_NAME}/providers/Microsoft.Sql/servers/${DB_HOST}/networking \n"

# #############################################################################
# Check password

echo -e "\nValidate or reset root password.  Could take 5min if resetting\n"

export DB_PASSWORD_CHANGED=""
if ! test_db_connect "$DBA_USERNAME" "${DBA_PASSWORD}" "$DB_HOST_FQDN" "$DB_PORT" "master"; then
    if [[ -n "$DB_HOST_CREATED" ]]; then
        echo "can't connect to newly created host"
        return 1;
    fi
    if ! AZ sql mi update --admin-password "${DBA_PASSWORD}" -n "${DB_HOST}" -g "${RG_NAME}"; then
        cat /tmp/az_stderr.$$
        return 1    
    fi

    DB_PASSWORD_CHANGED="1"
    if ! test_db_connect "$DBA_USERNAME" "${DBA_PASSWORD}" "$DB_HOST_FQDN" "$DB_PORT" "master"; then
        cat /tmp/az_stderr.$$; return 1;
    fi
fi

# #############################################################################
# save the credentials to secrets store for reuse

if [[ -z "$DELETE_DB_AFTER_SLEEP" ]] && [[ "${DB_HOST_CREATED}" == "1" || "${DB_PASSWORD_CHANGED}" == "1" ]]; then
    put_secrets
fi

# #############################################################################
echo -e "\nBilling ${RG_NAME}: https://portal.azure.com/#@${az_tenantDefaultDomain}/resource/subscriptions/${az_id}/resourceGroups/${RG_NAME}/costanalysis"

az resource list --query "[?resourceGroup=='$RG_NAME'].{ name: name, flavor: kind, resourceType: type, region: location }" --output table

