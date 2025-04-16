#!/usr/bin/env bash

# error out when undeclared variable is used
set -u 

# must be sourced for exports to continue to the next script
if [ "$0" == "$BASH_SOURCE" ]; then
  echo "Script is being executed directly. Please run as source $0"
  exit 1
fi

export AZ_DB_TYPE=sq
export AZ_DB_SUFFIX=sq
export CONNECTION_TYPE=SQLSERVER
export SOURCE_TYPE=$CONNECTION_TYPE

# auto set the connection name
if [[ "${WHOAMI}" == "lfcddemo" ]] && [[ -z "${CONNECTION_NAME}" || "${CONNECTION_NAME}" != *"-${AZ_DB_TYPE}" ]]; then
    CONNECTION_NAME="${WHOAMI}-${AZ_DB_TYPE}"
    echo -e "\nChanging the connection nam\n"
    echo -e "CONNECTION_NAME=$CONNECTION_NAME"
fi

# #############################################################################
# AZ Cloud

if ! AZ account show; then
    cat /tmp/dbx_stderr.$$ /tmp/az_stderr.$$
    return 1
fi
az_id="${az_id:-$(jq -r '.id' /tmp/az_stdout.$$)}" 
az_tenantDefaultDomain="${az_tenantDefaultDomain:-$(jq -r '.tenantDefaultDomain' /tmp/az_stdout.$$)}"
az_user_name="${az_user_name:-$(jq -r '.user.name' /tmp/az_stdout.$$)}"

if [[ -n "${CLOUD_LOCATION}" ]]; then 
    if ! AZ configure --defaults location="${CLOUD_LOCATION}" ; then
        cat /tmp/az_stderr.$$; return 1
    fi
fi

# multiples tags are defined correctly below.  NOT A MISTAKE
if ! AZ group show --resource-group "${RG_NAME}" ; then
    if ! AZ group create --resource-group "${RG_NAME}" \
        --tags "Owner=${DBX_USERNAME}" "${REMOVE_AFTER:+RemoveAfter=${REMOVE_AFTER}}" ; then
        cat /tmp/az_stderr.$$; return 1
    fi
fi
RG_NAME=$(jq -r .name /tmp/az_stdout.$$)
if ! AZ configure --defaults group="${RG_NAME}"; then 
    cat /tmp/az_stderr.$$; return 1
fi

echo -e "\nBilling ${RG_NAME}: https://portal.azure.com/#@${az_tenantDefaultDomain}/resource/subscriptions/${az_id}/resourceGroups/${RG_NAME}/costanalysis"


# #############################################################################
# export functions

password_reset_db() {
    if ! AZ sql server update -n "${DB_HOST}" --admin-password "${DBA_PASSWORD}" -g "${RG_NAME}"; then
        cat /tmp/az_stderr.$$; return 1;
    fi
}
export -f password_reset_db

start_db() {
    local skip_db_show="${1:-""}"

    if [[ -z "$skip_db_show" ]] && ! AZ sql db show -n "$DB_CATALOG" -s "$DB_HOST" -g "${RG_NAME}"; then cat /tmp/az_stderr.$$; return 1; fi
    if [[ "Online" == "$(jq -r '.state' /tmp/az_stdout.$$)" ]]; then CONNECT_TIMEOUT=10; else CONNECT_TIMEOUT=120; fi
    if ! test_db_connect "$DBA_USERNAME" "${DBA_PASSWORD}" "$DB_HOST_FQDN" "$DB_PORT" "$DB_CATALOG" "$CONNECT_TIMEOUT"; then
        cat /tmp/az_stderr.$$; return 1;
    fi
}
export -f start_db

stop_db() {
    echo "stop db not required"
}
export -f stop_db

delete_db() {
    if ! AZ sql server delete -y -n "${DB_HOST}" -g "${RG_NAME}"; then 
        cat /tmp/az_stderr.$$; return 1;
    fi
}
export -f delete_db

delete_catalog() {
    if ! AZ sql db delete -y -n "${DB_CATALOG}" -s "${DB_HOST}" -g "${RG_NAME}"; then 
        cat /tmp/az_stderr.$$; return 1;
    fi
}
export -f delete_catalog

show_firewall() {
    if ! AZ sql server firewall-rule list -s "${DB_HOST}" -g "${RG_NAME}"; then 
        cat /tmp/az_stderr.$$; return 1;
    fi
}
export -f show_firewall

firewall_rule_add() {
for fw_rule in "${@}"; do
    read -rd "\n" address host_min host_max <<< \
        "$(ipcalc -bn "${fw_rule}" | awk -F'[:[:space:]]+' '/^HostMin|^HostMax|^Address/ {print $(NF-1)}')"
    fw_rule_name="$(echo "${fw_rule}" | tr [./] _)"
    if [[ -z $host_min || -z $host_max ]]; then
        echo "${fw_rule} did not produce correct ${host_min} and/or ${host_max}.  Assuming /32"
        host_min="$address"
        host_max="$address"
    fi
    if ! AZ sql server firewall-rule show -n "${fw_rule_name}" -s "${DB_HOST}" -g "${RG_NAME}"; then
        if ! AZ sql server firewall-rule create -n "${fw_rule_name}" -s "$DB_HOST" -g "${RG_NAME}" --start-ip-address ${host_min} --end-ip-address "${host_max}"; then
            cat /tmp/az_stderr.$$; return 1;
        fi
    fi
done
}
# #############################################################################
# load secrets if exists

#echo -e "\nLoading previous secrets \n"

#get_secrets

# #############################################################################
# set default host and catalog if not specified

echo -e "\nLoading available host and catalog if not specified \n"

# make host name follow the naming convention
if [[ -n "$DB_HOST" && "$DB_HOST" != *"-${AZ_DB_SUFFIX}" ]]; then
    DB_HOST=""
    DB_HOST_FQDN=""
fi

# get avail sql server if not specified
if  [[ -z "$DB_HOST" ||  "$DB_HOST_FQDN" != "$DB_HOST."* ]] && \
    [[ -z "$AZ_DB_TYPE" || "$AZ_DB_TYPE" == "sq" ]] && \
    AZ sql server list -g "${RG_NAME}"; then
    
    read -rd "\n" x1 x2 x3 <<< "$(jq -r 'first(.[] | select(.fullyQualifiedDomainName!=null and .type=="Microsoft.Sql/servers")) | .name, .fullyQualifiedDomainName, .administratorLogin' /tmp/az_stdout.$$)"
    if [[ -n $x1 && -n $x2 && -n $x3 ]]; then DB_HOST="$x1"; DB_HOST_FQDN="$x2"; DBA_USERNAME="$x3"; fi
fi

# get avail catalog if not specified
if [[ -n "$DB_HOST" ]] && [[ -z "$DB_CATALOG" || "$DB_CATALOG" == "$CATALOG_BASENAME" ]] && \
    AZ sql db list -s "$DB_HOST" -g "${RG_NAME}"; then

    x1=""
    # check if secrets exists for this host
    if get_secrets $DB_HOST; then
        # reuse catalog from the secret if exists?
        x1="$(jq -r --arg DB_CATALOG $DB_CATALOG 'first(.[] | select(.name == $DB_CATALOG) | .name)' /tmp/az_stdout.$$)"
    fi

    # first free catalog exists?
    if [[ -z $x1 ]]; then
        x1="$(jq -r --arg DB_CATALOG "master" 'first(.[] | select(.name != $DB_CATALOG and .useFreeLimit == true) | .name)' /tmp/az_stdout.$$)"
    fi

    if [[ -z $x1 ]]; then 
        # first non free catalog exits?
        x1="$(jq -r --arg DB_CATALOG "master" 'first(.[] | select(.name != $DB_CATALOG and .useFreeLimit == true) | .name)' /tmp/az_stdout.$$)"
    fi
    if [[ -n $x1 ]]; then DB_CATALOG="$x1"; fi
fi

# secrets was empty or invalid.
if [[ -z "${DBA_USERNAME}" || -z "${DB_CATALOG}" || -z "$DB_HOST" || "$DB_HOST" != *"-${AZ_DB_SUFFIX}" ]]; then 
    DB_HOST="${DB_BASENAME}-${AZ_DB_SUFFIX}"; 
    DB_CATALOG="$CATALOG_BASENAME"
fi  

if [[ -n "$DB_HOST_FQDN" && -n "$DB_HOST" ]]; then
    echo "az sql server/catalog: $DB_HOST $DBA_USERNAME@$DB_HOST_FQDN:$DB_PORT/$DB_CATALOG"
fi

export DB_PORT=1433

# #############################################################################
# create sql server

echo -e "\nCreate sql server if not exists\n"

export DB_HOST_CREATED=""
if ! AZ sql server show -n "${DB_HOST}" -g "${RG_NAME}"; then
    # sql server create does not support tags
    if ! AZ sql server create -n "${DB_HOST}" -g "${RG_NAME}" \
        --admin-user "${DBA_USERNAME}" \
        --admin-password "${DBA_PASSWORD}"; then
        cat /tmp/az_stderr.$$; return 1;
    fi
    DB_HOST_CREATED="1"
    if [[ -n "$DELETE_DB_AFTER_SLEEP" ]]; then
        # </dev/null solves Fatal Python error: init_sys_streams: can't initialize sys standard streams
        nohup sleep "${DELETE_DB_AFTER_SLEEP}" && AZ sql server delete -y -n "${DB_HOST}" -g "${RG_NAME}" </dev/null >> ~/nohup.out 2>&1 &
        echo -e "\nDeleting sqlserver ${DB_HOST} after ${DELETE_DB_AFTER_SLEEP}.  To cancel kill -9 $! \n" 
    fi
else
    read -rd "\n" x1 x2 x3 <<< "$(jq -r 'select(.fullyQualifiedDomainName!=null and .type=="Microsoft.Sql/servers") | .name, .fullyQualifiedDomainName, .administratorLogin' /tmp/az_stdout.$$)"
    if [[ -z $x1 || -z $x2 || -z $x3 ]]; then 
        echo "$DB_HOST is not a Microsoft.Sql/servers"
        return 1
    fi
fi

read_fqdn_dba_if_host
if ! AZ configure --defaults sql-server="${DB_HOST}"; then
    cat /tmp/az_stderr.$$; return 1;
fi

echo "AZ sql ${DB_HOST}: https://portal.azure.com/#@${az_tenantDefaultDomain}/resource/subscriptions/${az_id}/resourceGroups/${RG_NAME}/providers/Microsoft.Sql/servers/${DB_HOST}/overview"
echo ""

# #############################################################################
# create catalog if not existss - free, if not avail, then paid version

echo -e "\nCreate catalog if not exists\n" 

if ! AZ sql db show -n "${DB_CATALOG}" -s "${DB_HOST}" -g "${RG_NAME}"; then

    if ! AZ sql db create -n "${DB_CATALOG}" -s "${DB_HOST}" -g "${RG_NAME}" -e GeneralPurpose -f Gen5 -c 1 \
        --tags "Owner=${DBX_USERNAME}" "${REMOVE_AFTER:+RemoveAfter=${REMOVE_AFTER}}" \
        --compute-model Serverless --backup-storage-redundancy Local \
        --zone-redundant false --exhaustion-behavior AutoPause --use-free-limit \
         ; then 

        # delete any leftover
        cat /tmp/az_stderr.$$
        AZ sql db delete -y -n "${DB_CATALOG}" -s "${DB_HOST}" -g "${RG_NAME}"

        if ! AZ sql db create -n "${DB_CATALOG}" -s "${DB_HOST}" -g "${RG_NAME}" -e GeneralPurpose -f Gen5 -c 1 \
            --tags "Owner=${DBX_USERNAME}" "${REMOVE_AFTER:+RemoveAfter=${REMOVE_AFTER}}" \
            --compute-model Serverless --backup-storage-redundancy Local \
            --zone-redundant false --exhaustion-behavior AutoPause --auto-pause-delay 15 \
             ; then
            cat /tmp/az_stderr.$$; return 1;
        fi
    fi 
    if [[ -n "$DELETE_DB_AFTER_SLEEP" ]]; then
        # </dev/null solves Fatal Python error: init_sys_streams: can't initialize sys standard streams
        nohup sleep "${DELETE_DB_AFTER_SLEEP}" && AZ sql db delete -y -n "${DB_CATALOG}" -s "${DB_HOST}" -g "${RG_NAME}" </dev/null >> ~/nohup.out 2>&1 &
        echo -e "\nDeleting catalog ${DB_CATALOG} after ${DELETE_DB_AFTER_SLEEP}.  To cancel kill -9 $! \n" 
    fi
fi

echo "AZ sql db ${DB_CATALOG}: https://portal.azure.com/#@${az_tenantDefaultDomain}/resource/subscriptions/${az_id}/resourceGroups/${RG_NAME}/providers/Microsoft.Sql/servers/${DB_HOST}/databases/${DB_CATALOG}/overview"
echo ""

# #############################################################################

# Run firewall rules before coming here

echo -e "Creating permissive firewall rules if not exists\n"

# convert CIDR to range 

if ! AZ sql server firewall-rule list -s "${DB_HOST}" -g "${RG_NAME}"; then cat /tmp/az_stderr.$$; return 1; fi
if [[ "0" == "$(jq length /tmp/az_stdout.$$)" ]]; then
    firewall_rule_add "${DB_FIREWALL_CIDRS[@]}"
fi

echo "AZ sql server firewall-rule ${DB_HOST}: https://portal.azure.com/#@${az_tenantDefaultDomain}/resource/subscriptions/${az_id}/resourceGroups/${RG_NAME}/providers/Microsoft.Sql/servers/${DB_HOST}/networking"
echo ""

# #############################################################################
# Check password

echo -e "\nValidate or reset root password.  Could take 5min if resetting\n"

export DB_PASSWORD_CHANGED=""
if ! test_db_connect "$DBA_USERNAME" "${DBA_PASSWORD}" "$DB_HOST_FQDN" "$DB_PORT" "master"; then
    if [[ -n "$DB_HOST_CREATED" ]]; then
        echo "can't connect to newly created host"
        return 1;
    fi

    password_reset_db

    DB_PASSWORD_CHANGED="1"
    if ! test_db_connect "$DBA_USERNAME" "${DBA_PASSWORD}" "$DB_HOST_FQDN" "$DB_PORT" "master"; then
        cat /tmp/az_stderr.$$; return 1;
    fi
fi

# make sure user catalog is online
start_db

# #############################################################################
# save the credentials to secrets store for reuse

if [[ -z "$DELETE_DB_AFTER_SLEEP" ]] && [[ "${DB_HOST_CREATED}" == "1" || "${DB_PASSWORD_CHANGED}" == "1" ]]; then
    put_secrets
fi

# #############################################################################
echo -e "\nBilling ${RG_NAME}: https://portal.azure.com/#@${az_tenantDefaultDomain}/resource/subscriptions/${az_id}/resourceGroups/${RG_NAME}/costanalysis"
echo ""

az resource list --query "[?resourceGroup=='$RG_NAME'].{ name: name, flavor: kind, resourceType: type, region: location }" --output table
