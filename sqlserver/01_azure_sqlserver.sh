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
 [[ -z "${DB_HOST}" ]] || \
 [[ -z $DB_PORT ]] || \
 [[ -z "${DBA_PASSWORD}" ]] || \
 [[ -z "${USER_PASSWORD}" ]] || \
 [[ -z $DBA_USERNAME ]] || \
 [[ -z $USER_USERNAME ]] || \
 [[ -z $DB_HOST_FQDN ]]; then 
    if [[ -f ./00_lakeflow_connect_env.sh ]]; then
        source ./00_lakeflow_connect_env.sh
    else
        source <(curl -s -L https://raw.githubusercontent.com/rsleedbx/lakeflow_connect/refs/heads/sqlserver/sqlserver/00_lakeflow_connect_env.sh)
    fi
fi

if [[ -f ./00_az_env.sh ]]; then
    source ./00_az_env.sh
else
    source <(curl -s -L https://raw.githubusercontent.com/rsleedbx/lakeflow_connect/refs/heads/sqlserver/sqlserver/00_az_env.sh)
fi

# #############################################################################
# create sql server

echo -e "\nCreating sql server\n"

if ! AZ sql server show --name "${DB_HOST}" -g "${RG_NAME}"; then
    if ! AZ sql server create --name "${DB_HOST}" -g "${RG_NAME}" \
        --admin-user "${DBA_USERNAME}" \
        --admin-password "${DBA_PASSWORD}"; then
        cat /tmp/az_stderr.$$; return 1;
    fi
    read -rd "\n" DB_HOST DB_HOST_FQDN DBA_USERNAME <<< "$(jq -r '.name, .fullyQualifiedDomainName, .administratorLogin' /tmp/az_stdout.$$)"
    if [[ -n "$DELETE_DB_AFTER_SLEEP" ]]; then
        nohup sleep "${DELETE_DB_AFTER_SLEEP}" && AZ sql server delete -y -n "$DB_HOST" -g "${RG_NAME}" >> ~/nohup.out 2>&1 &
    fi
fi
if ! AZ configure --defaults sql-server="${DB_HOST}"; then
    cat /tmp/az_stderr.$$; return 1;
fi

echo "AZ sql ${DB_HOST}: https://portal.azure.com/#@${az_tenantDefaultDomain}/resource/subscriptions/${az_id}/resourceGroups/${RG_NAME}/providers/Microsoft.Sql/servers/${DB_HOST}/overview"
echo ""

# #############################################################################
# create catalog if not exists - free, if not avail, then paid version

echo -e "\nCreating catalog\n" 

if ! AZ sql db show --name ${DB_CATALOG} -g "${RG_NAME}"; then

    if ! AZ sql db create --name "${DB_CATALOG}" -s "${DB_HOST}" -g "${RG_NAME}" -e GeneralPurpose -f Gen5 -c 1 \
        --compute-model Serverless --backup-storage-redundancy Local \
        --zone-redundant false --exhaustion-behavior AutoPause --use-free-limit \
         ; then 

        if ! AZ sql db create --name "${DB_CATALOG}" -s "${DB_HOST}" -g "${RG_NAME}" -e GeneralPurpose -f Gen5 -c 1 \
            --compute-model Serverless --backup-storage-redundancy Local \
            --zone-redundant false --exhaustion-behavior AutoPause --auto-pause-delay 15 \
             ; then
            cat /tmp/az_stderr.$$; return 1;
        fi
    fi 
    if [[ -n "$DELETE_DB_AFTER_SLEEP" ]]; then
        nohup sleep "${DELETE_DB_AFTER_SLEEP}" && AZ sql db delete -y -n "${DB_CATALOG}" -s "$DB_HOST" -g "${RG_NAME}" >> ~/nohup.out 2>&1 &
    fi
fi

echo "AZ sql db ${DB_CATALOG}: https://portal.azure.com/#@${az_tenantDefaultDomain}/resource/subscriptions/${az_id}/resourceGroups/${RG_NAME}/providers/Microsoft.Sql/servers/${DB_HOST}/databases/${DB_CATALOG}/overview"
echo ""

# #############################################################################

# Run firewall rules before coming here

echo -e "Creating permissive firewall rules\n"

# convert CIDR to range 
declare -A fw_rules
for fw_rule in "${DB_FIREWALL_CIDRS[@]}"; do # "${array[@]}" = single word at a time
    read -rd "\n" host_min host_max <<< \
        "$(ipcalc -bn "${fw_rule}" | awk -F'[:[:space:]]+' '/^HostMin|^HostMax/ {print $(NF-1)}')"
    fw_rule_name="$(echo "${fw_rule}" | tr [./] _)"
    if ! AZ sql server firewall-rule show -n "${fw_rule_name}"; then
        if ! AZ sql server firewall-rule create -n "${fw_rule_name}" -s "$DB_HOST" -g "${RG_NAME}" --start-ip-address ${host_min} --end-ip-address "${host_max}"; then
            cat /tmp/az_stderr.$$; return 1;
        fi
    fi
done 

echo "AZ sql server firewall-rule ${DB_HOST}: https://portal.azure.com/#@${az_tenantDefaultDomain}/resource/subscriptions/${az_id}/resourceGroups/${RG_NAME}/providers/Microsoft.Sql/servers/${DB_HOST}/networking"
echo ""

# #############################################################################
# Check password

echo -e "\nValidate root password\n"
if ! test_db_connect "$DBA_USERNAME" "${DBA_PASSWORD}" "$DB_HOST_FQDN" "$DB_PORT" "master"; then
    if ! AZ sql server update --name "${DB_HOST}" -g "${RG_NAME}" --admin-password "${DBA_PASSWORD}"; then
        cat /tmp/az_stderr.$$; return 1;
    fi
    if ! test_db_connect "$DBA_USERNAME" "${DBA_PASSWORD}" "$DB_HOST_FQDN" "$DB_PORT" "master"; then
        cat /tmp/az_stderr.$$; return 1;
    fi
fi

# #############################################################################
echo -e "\nBilling : https://portal.azure.com/#view/Microsoft_Azure_CostManagement/Menu/~/costanalysis"
echo ""


# #############################################################################
# export functions

password_reset_db() {
    if ! AZ sql server update --name "${DB_HOST}" --admin-password "${DBA_PASSWORD}"; then
        cat /tmp/az_stderr.$$; return 1;
    fi
}
export -f password_reset_db

stop_db() {
    echo "stop db not required"
}
export -f stop_db

delete_db() {
    echo "AZ sql ${DB_HOST}: delete started"
    AZ sql server delete -y --name "${DB_HOST}"
    echo "AZ sql ${DB_HOST}: delete completed"
}
export -f delete_db

show_firewall() {
    AZ sql server firewall-rule list
}
export -f show_firewall