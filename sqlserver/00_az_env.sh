#!/usr/bin/env bash

# #############################################################################

echo -e "\nGetting az_id az_tenantDefaultDomain\n"

if [[ -z "$az_id" ]] || [[ -z "$az_tenantDefaultDomain" ]]; then
    if ! AZ account show ; then 
        cat /tmp/az_stderr.$$; return 1
    fi
    read -rd "\n" az_id az_tenantDefaultDomain <<< "$(jq -r '.id, .tenantDefaultDomain' /tmp/az_stdout.$$)"
    export az_id
    export az_tenantDefaultDomain
fi

# #############################################################################

echo -e "\nSetting cloud location\n"

if [[ -n "${CLOUD_LOCATION}" ]]; then 
    if ! AZ configure --defaults location="${CLOUD_LOCATION}" ; then
        cat /tmp/az_stderr.$$; return 1
    fi
fi

# #############################################################################
# create resource group 
# https://learn.microsoft.com/en-us/azure/azure-resource-manager/management/manage-resource-groups-cli

echo -e "\nCreating resource group\n"

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
