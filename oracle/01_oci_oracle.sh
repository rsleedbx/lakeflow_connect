#!/usr/bin/env bash

# error out when undeclared variable is used
set -u 

# must be sourced for exports to continue to the next script
if [ "$0" == "$BASH_SOURCE" ]; then
  echo "Script is being executed directly. Please run as source $0"
  exit 1
fi

export DB_TYPE=oci-oracle-19c
export DB_SUFFIX=oci-oracle-19c
export DB_CLOUD=oci
export CONNECTION_TYPE=ORACLE
export SOURCE_TYPE=$CONNECTION_TYPE

# auto set the connection name
if [[ "${WHOAMI}" == "lfcddemo" ]] && [[ -z "${CONNECTION_NAME}" || "${CONNECTION_NAME}" != *"-${DB_TYPE}" ]]; then
    CONNECTION_NAME="${WHOAMI}-${DB_TYPE}"
    echo -e "\nChanging the connection nam\n"
    echo -e "CONNECTION_NAME=$CONNECTION_NAME"
fi

# #############################################################################
# OCI Cloud

OCI_INIT

# #############################################################################
# export functions

SQLCLI() {
    ORACLECLI "${@}"
}
export -f SQLCLI

SQLCLI_DBA() {
    DB_USERNAME="${DBA_USERNAME}" DB_PASSWORD="${DBA_PASSWORD}" ORACLECLI "${@}"
}
export -f SQLCLI_DBA

SQLCLI_USER() {
    DB_USERNAME="${USER_USERNAME}" DB_PASSWORD="${USER_PASSWORD}" ORACLECLI "${@}"
}
export -f SQLCLI_USER

password_reset_db() {
    if ! OCI oracle flexible-server update -y -n "${DB_HOST}" --admin-password "${DBA_PASSWORD}" -g "${RG_NAME}"; then
        cat /tmp/az_stderr.$$
        return 1
    fi
}
export -f password_reset_db


delete_db() {
    DB_EXIT_ON_ERROR="PRINT_EXIT" OCI oracle flexible-server delete -y -n "${DB_HOST}" -g "${RG_NAME}"
}
export -f delete_db

firewall_rule_add() {
for fw_rule in "${@}"; do
    read -rd "\n" address host_min host_max <<< \
        "$(ipcalc -bn "${fw_rule}" | awk -F'[:[:space:]]+' '/^HostMin|^HostMax|^Address/ {print $(NF-1)}')"
    fw_rule_name="$(echo "${fw_rule}" | tr [./] _)"
    if [[ -z $host_min || -z $host_max ]]; then
        #echo "${fw_rule} did not produce correct ${host_min} and/or ${host_max}.  Assuming /32"
        host_min="$address"
        host_max="$address"
    fi
    if ! OCI  oracle flexible-server firewall-rule show --rule-name "${fw_rule_name}" --name "${DB_HOST}" -g "${RG_NAME}"; then
        DB_EXIT_ON_ERROR="PRINT_EXIT" OCI oracle flexible-server firewall-rule create --rule-name "${fw_rule_name}" --name "$DB_HOST" -g "${RG_NAME}" --start-ip-address "${host_min}" --end-ip-address "${host_max}"
    fi
done
}

# make sure to quote echo "$sql_dml_generator" otherwise the newline will be removed 
export sql_dml_generator='
set search_path='${DB_SCHEMA}';
do $$
declare 
    counter integer := 0;
begin
    while counter >= 0 loop
        -- intpk
        insert into intpk (dt) values (CURRENT_TIMESTAMP),(CURRENT_TIMESTAMP), (CURRENT_TIMESTAMP);
        commit;
        delete from intpk where pk=(select min(pk) from intpk);
        commit;
        update intpk set dt=CURRENT_TIMESTAMP where pk=(select min(pk) from intpk);
        commit;
        -- dtix
        insert into dtix (dt) values (CURRENT_TIMESTAMP),(CURRENT_TIMESTAMP),(CURRENT_TIMESTAMP);
        commit;
        -- wait
		raise notice '"'Counter %'"', counter;
	    counter := counter + 1;
        perform oracle_sleep(1);
    end loop;
end;
$$;
'

# #############################################################################
# set default host and catalog if not specified

echo -e "\nLoading available host and catalog if not specified"
echo -e   "---------------------------------------------------\n"

# make host name follow the naming convention
if [[ -n "$DB_HOST" && "$DB_HOST" != *"-${DB_SUFFIX}" ]]; then
    DB_HOST=""
    DB_HOST_FQDN=""
fi

# get avail server if not specified
if  [[ -z "$DB_HOST" ||  "$DB_HOST_FQDN" != "$DB_HOST."* ]] && \
    OCI db autonomous-database list; then

if ! DB_STDOUT="/tmp/oci_db_list.$$" OCI db autonomous-database list --query "data[?\"display-name\" == '$DB_HOST']" | jq -e '.[] | ."display-name"' /tmp/oci_db_list.$$; then
    echo "create db"
fi


    read -rd "\n" x1 x2 x3 <<< "$(jq -r 'first(.[] | select(.fullyQualifiedDomainName!=null and .type=="Microsoft.DBforOracle/flexibleServers")) | .name, .fullyQualifiedDomainName, .administratorLogin' /tmp/az_stdout.$$)"
    if [[ -n $x1 && -n $x2 && -n $x3 && "$x1" == *"-${DB_SUFFIX}" ]]; then 
        DB_HOST="$x1"; DB_HOST_FQDN="$x2"; DBA_USERNAME="$x3"; 
    fi
fi

# get avail catalog if not specified
STATE[secrets_retrieved]=0
if [[ -n "$DB_HOST" ]] && [[ -z "$DB_CATALOG" || "$DB_CATALOG" == "$CATALOG_BASENAME" ]]; then

    # check if secrets exists for this host
    if get_secrets "$DB_HOST"; then
        STATE[secrets_retrieved]=1
        echo -e "\n USING VALUES FROM SECRETS \v"
    fi
fi

STATE[secrets_valid]=1
# secrets was empty or invalid.
if [[ -z "${DBA_USERNAME}" || -z "$DB_HOST" || "$DB_HOST" != *"-${DB_SUFFIX}" ]]; then 
    STATE[secrets_valid]=0
    DB_HOST="${DB_BASENAME}-${DB_SUFFIX}"; 
fi  

if [[ -z "${DB_CATALOG}" || "$DB_CATALOG" == "$CATALOG_BASENAME" ]]; then 
    DB_CATALOG="${CATALOG_BASENAME}"
fi  

export DB_PORT=1522

# #############################################################################
# create sql server

echo -e "\nCreate database server if not exists"
echo -e   "------------------------------------\n"


export DB_HOST_CREATED=""
if ! OCI db autonomous-database list; then

    DB_EXIT_ON_ERROR="PRINT_EXIT" OCI provider register --wait --namespace Microsoft.DBforOracle

    # sql server create does not support tags
    DB_EXIT_ON_ERROR="PRINT_EXIT" OCI db autonomous-database create \
        --is-free-tier TRUE \
        --db-name $DB_HOST \
        --admin-password $DBA_PASSWORD \
        --cpu-core-count 1 \
        --data-storage-size-in-tbs 1 \
        --db-workload ATP # or ADW for Autonomous Data Warehouse

    DB_HOST_CREATED="1"
    if [[ -n "$DELETE_DB_AFTER_SLEEP" ]]; then
        # </dev/null solves Fatal Python error: init_sys_streams: can't initialize sys standard streams
        nohup sleep "${DELETE_DB_AFTER_SLEEP}" && OCI oracle flexible-server delete -y -n "${DB_HOST}" -g "${RG_NAME}" </dev/null >> ~/nohup.out 2>&1 &
        echo -e "\nDeleting ${DB_HOST} after ${DELETE_DB_AFTER_SLEEP}.  To cancel kill -9 $! \n" 
    fi

    read -rd "\n" x1 x2 <<< "$(jq -r 'select(.host!=null) | .host, .username' /tmp/az_stdout.$$)"
    DB_HOST_FQDN=$x1; DBA_USERNAME="$x2";
else
    read -rd "\n" x1 x2 x3 <<< "$(jq -r 'select(.fullyQualifiedDomainName!=null and .type=="Microsoft.DBforOracle/flexibleServers") | .name, .fullyQualifiedDomainName, .administratorLogin' /tmp/az_stdout.$$)"
    if [[ -z $x1 || -z $x2 || -z $x3 ]]; then 
        echo "$DB_HOST is not a Microsoft.DBforOracle/flexibleServers"
        return 1
    fi
    DB_HOST="$x1"; DB_HOST_FQDN="$x2"; DBA_USERNAME="$x3"; 
fi

echo "OCI oracle ${DB_HOST}: https://portal.oci.com/#@${az_tenantDefaultDomain}/resource/subscriptions/${az_id}/resourceGroups/${RG_NAME}/providers/Microsoft.DBforOracle/flexibleServers/${DB_HOST}/overview"
echo ""

return 1

# #############################################################################

# Run firewall rules before coming here

echo -e "Creating permissive firewall rules if not exists"
echo -e "------------------------------------------------\n"

# convert CIDR to range 

DB_EXIT_ON_ERROR="PRINT_EXIT"  OCI oracle flexible-server firewall-rule list -n "${DB_HOST}" -g "${RG_NAME}"
if [[ "0" == "$(jq length /tmp/az_stdout.$$)" ]]; then
    firewall_rule_add "${DB_FIREWALL_CIDRS[@]}"
fi

echo -e "\nAZ sql server firewall-rule ${DB_HOST}: https://portal.oci.com/#@${az_tenantDefaultDomain}/resource/subscriptions/${az_id}/resourceGroups/${RG_NAME}/providers/Microsoft.DBforOracle/flexibleServers/${DB_HOST}/networking \n"

# #############################################################################
# Check password

echo -e "\nValidate or reset root password.  Could take 5min if resetting"
echo -e   "--------------------------------------------------------------\n"

export DB_PASSWORD_CHANGED=""
if ! DB_USERNAME="$DBA_USERNAME" DB_PASSWORD="$DBA_PASSWORD" DB_CATALOG="oracle" TEST_DB_CONNECT; then
    if [[ -n "$DB_HOST_CREATED" ]]; then
        echo "can't connect to newly created host"
        cat /tmp/oracle_stdout.$$ /tmp/oracle_stderr.$$
        return 1
    fi

    password_reset_db

    DB_PASSWORD_CHANGED="1"
    if ! DB_USERNAME="$DBA_USERNAME" DB_PASSWORD="$DBA_PASSWORD" DB_CATALOG="oracle" TEST_DB_CONNECT; then
        cat /tmp/oracle_stdout.$$ /tmp/oracle_stderr.$$
        return 1
    fi
fi

# #############################################################################
# create catalog does not exist for Oracle


# #############################################################################
# set replication

echo -e "\nEnable binlog_row_image=full, binlog_format=row and require_secure_transport=off" 
echo -e   "--------------------------------------------------------------------------------\n"

PARAMETER_SET=""
DB_EXIT_ON_ERROR="PRINT_EXIT" DB_STDOUT=/tmp/az_parm_list.$$ OCI oracle flexible-server parameter list --server-name "$DB_HOST"

# lakeflow connect 
if [[ "on" == "$(jq -r '.[] | select(.name == "sql_generate_invisible_primary_key") | .currentValue | ascii_downcase' /tmp/az_parm_list.$$)" ]]; then
    DB_EXIT_ON_ERROR="PRINT_EXIT"  OCI oracle flexible-server parameter set --server-name "$DB_HOST" --name  sql_generate_invisible_primary_key --value OFF
    PARAMETER_SET="1"
fi

if [[ "full" != "$(jq -r '.[] | select(.name == "binlog_row_image") | .currentValue | ascii_downcase' /tmp/az_parm_list.$$)" ]]; then
    DB_EXIT_ON_ERROR="PRINT_EXIT"  OCI oracle flexible-server parameter set --server-name "$DB_HOST" --name  binlog_row_image --value full
    PARAMETER_SET="1"
fi

if [[ "row" != "$(jq -r '.[] | select(.name == "binlog_format") | .currentValue | ascii_downcase' /tmp/az_parm_list.$$)" ]]; then
    DB_EXIT_ON_ERROR="PRINT_EXIT"  OCI oracle flexible-server parameter set --server-name "$DB_HOST" --name  binlog_format --value row
    PARAMETER_SET="1"
fi

# lakeflow connect expects ssl disabled for now
if [[ "off" != "$(jq -r '.[] | select(.name == "require_secure_transport") | .currentValue | ascii_downcase' /tmp/az_parm_list.$$)" ]]; then
    DB_EXIT_ON_ERROR="PRINT_EXIT"  OCI oracle flexible-server parameter set --server-name "$DB_HOST" --name  require_secure_transport --value off
    PARAMETER_SET="1"
fi

if [[ 604800 -gt "$(jq -r '.[] | select(.name == "binlog_expire_logs_seconds") | .currentValue | ascii_downcase' /tmp/az_parm_list.$$)" ]]; then
    DB_EXIT_ON_ERROR="PRINT_EXIT"  OCI oracle flexible-server parameter set --server-name "$DB_HOST" --name  binlog_expire_logs_seconds --value 604800
    PARAMETER_SET="1"
fi

# restart to take effect
if [[ "$PARAMETER_SET" == "1" ]]; then 
    DB_EXIT_ON_ERROR="PRINT_EXIT"  OCI oracle flexible-server restart --name "$DB_HOST"
fi

# #############################################################################
# save the credentials to secrets store for reuse

# check return code instead of echo values
if should_save_secrets; then 
    put_secrets                             # bash export format
    put_secrets "${DB_HOST}_json" "json"    # json format for easier parsing
fi

# #############################################################################
echo -e "\nResource list"
echo -e   "-------------\n"

oci resource list --query "[?resourceGroup=='$RG_NAME'].{ name: name, flavor: kind, resourceType: type, region: location }" --output table
