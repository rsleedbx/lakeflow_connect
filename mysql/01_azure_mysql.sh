#!/usr/bin/env bash

# error out when undeclared variable is used
set -u 

# must be sourced for exports to continue to the next script
if [ "$0" == "$BASH_SOURCE" ]; then
  echo "Script is being executed directly. Please run as source $0"
  exit 1
fi

export CLOUD_DB_TYPE=azure-mysql
export DB_TYPE=azure-mysql
export DB_SUFFIX=azure-mysql
export CONNECTION_TYPE=MYSQL
export SOURCE_TYPE=$CONNECTION_TYPE
# Azure Flex major version for create: 5.7 | 8.0 | 8.4 (general_log writable on 5.7; read-only on 8.4)
export MYSQL_VERSION="${MYSQL_VERSION:-8.4}"

# auto set the connection name
if [[ "${WHOAMI}" == "lfcddemo" ]] && [[ -z "${CONNECTION_NAME}" || "${CONNECTION_NAME}" != *"-${DB_TYPE}" ]]; then
    CONNECTION_NAME="${WHOAMI}-${DB_TYPE}"
    echo -e "\nChanging the connection nam\n"
    echo -e "CONNECTION_NAME=$CONNECTION_NAME"
fi

# #############################################################################
# AZ Cloud

AZ_INIT

_LFC_REPO_ROOT="${_LFC_REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
export _LFC_REPO_ROOT

# #############################################################################
# export functions

SQLCLI() {
    DB_USERNAME="${DB_USERNAME:-$USER_USERNAME}" DB_PASSWORD="${DB_PASSWORD-$USER_PASSWORD}" DB_CATALOG="${DB_CATALOG:-$DB_SCHEMA}" MYSQLCLI "${@}"
}
export -f SQLCLI

# Helper to run SQL as DBA (default catalog mysql system schema)
SQLCLI_DBA() {
    DB_USERNAME="${DBA_USERNAME}" DB_PASSWORD="${DBA_PASSWORD}" DB_CATALOG="${DB_CATALOG:-mysql}" MYSQLCLI "${@}"
}
export -f SQLCLI_DBA

SQLCLI_USER() {
    DB_USERNAME="${USER_USERNAME}" DB_PASSWORD="${USER_PASSWORD}" DB_CATALOG="${DB_CATALOG:-$DB_SCHEMA}" MYSQLCLI "${@}"
}
export -f SQLCLI_USER

password_reset_db() {
    CMD_EXIT_ON_ERROR=PRINT_EXIT
    cmd_mask_azure_secrets
    CMD az mysql flexible-server update -n "${DB_HOST}" --admin-password "${DBA_PASSWORD}" -g "${RG_NAME}"
}
export -f password_reset_db

delete_db() {
    CMD_EXIT_ON_ERROR=PRINT_EXIT
    cmd_mask_azure_secrets
    CMD az mysql flexible-server delete -y -n "${DB_HOST}" -g "${RG_NAME}"
}
export -f delete_db

firewall_rule_add() {
    # Thin wrapper: list current rules, then sync via utils/azure-sql-firewall-rule.py
    # Optional args are ignored; desired CIDRs come from DB_FIREWALL_CIDRS.
    local _lfc_root="${_LFC_REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
    CMD_EXIT_ON_ERROR=PRINT_EXIT
    cmd_mask_azure_secrets
    CMD az mysql flexible-server firewall-rule list -n "${DB_HOST}" -g "${RG_NAME}"
    python3 "${_lfc_root}/utils/azure-sql-firewall-rule.py" \
        --kind mysql \
        --server "${DB_HOST}" \
        -g "${RG_NAME}" \
        --existing-rules "/tmp/az_stdout.$$" \
        --my-ip \
        --apply
}
export -f firewall_rule_add

# #############################################################################
# set default host and catalog if not specified

echo -e "\nLoading available host and catalog if not specified"
echo -e   "---------------------------------------------------\n"

# make host name follow the naming convention
if [[ -n "$DB_HOST" && "$DB_HOST" != *"-${DB_SUFFIX}" ]]; then
    DB_HOST=""
    DB_HOST_FQDN=""
fi

# pick first server in RG only when DB_HOST was not set (user-set DB_HOST wins)
if [[ -z "$DB_HOST" ]]; then
    cmd_mask_azure_secrets
    CMD_EXIT_ON_ERROR=
    if CMD az mysql flexible-server list -g "${RG_NAME}"; then
        read -rd "\n" x1 x2 x3 <<< "$(jq -r --arg suffix "-${DB_SUFFIX}" \
          'first(.[] | select(.fullyQualifiedDomainName!=null and .type=="Microsoft.DBforMySQL/flexibleServers" and (.name | endswith($suffix)))) | .name, .fullyQualifiedDomainName, .administratorLogin' \
          /tmp/az_stdout.$$)"
        if [[ -n $x1 && -n $x2 && -n $x3 ]]; then
            DB_HOST="$x1"; DB_HOST_FQDN="$x2"; DBA_USERNAME="$x3";
        fi
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
    DB_CATALOG="${DB_SCHEMA}"
fi
export DB_CATALOG

export DB_PORT=3306

# #############################################################################
# create sql server

echo -e "\nCreate database server if not exists"
echo -e   "------------------------------------\n"


export DB_HOST_CREATED=""
cmd_mask_azure_secrets
CMD_EXIT_ON_ERROR=
if ! CMD az mysql flexible-server show -n "${DB_HOST}" -g "${RG_NAME}"; then

    CMD_EXIT_ON_ERROR=PRINT_EXIT
    cmd_mask_azure_secrets
    CMD az provider register --wait --namespace Microsoft.DBforMySQL

    # sql server create does not support tags
    CMD_EXIT_ON_ERROR=PRINT_EXIT
    cmd_mask_azure_secrets
    if ! CMD az mysql flexible-server create -n "${DB_HOST}" -g "${RG_NAME}" \
        --tags "Owner=${DBX_USERNAME}" "${REMOVE_AFTER:+RemoveAfter=${REMOVE_AFTER}}" \
        --database-name "${DB_SCHEMA}" \
        --version "${MYSQL_VERSION}" \
        --public-access Enabled \
        --storage-size 32 \
        --tier Burstable \
        --sku-name Standard_B1ms \
        --admin-user "${DBA_USERNAME}" \
        --admin-password "${DBA_PASSWORD}"; then
        return 1
    fi

    DB_HOST_CREATED="1"
    if [[ -n "$DELETE_DB_AFTER_SLEEP" ]]; then
        # </dev/null solves Fatal Python error: init_sys_streams: can't initialize sys standard streams
        nohup sleep "${DELETE_DB_AFTER_SLEEP}" && cmd_mask_azure_secrets && CMD az mysql flexible-server delete -y -n "${DB_HOST}" -g "${RG_NAME}" </dev/null >> ~/nohup.out 2>&1 &
        echo -e "\nDeleting ${DB_HOST} after ${DELETE_DB_AFTER_SLEEP}.  To cancel kill -9 $! \n" 
    fi

    read -rd "\n" x1 x2 <<< "$(jq -r 'select(.host!=null) | .host, .username' /tmp/az_stdout.$$)"
    DB_HOST_FQDN=$x1; DBA_USERNAME="$x2";
else
    read -rd "\n" x1 x2 x3 <<< "$(jq -r 'select(.fullyQualifiedDomainName!=null and .type=="Microsoft.DBforMySQL/flexibleServers") | .name, .fullyQualifiedDomainName, .administratorLogin' /tmp/az_stdout.$$)"
    if [[ -z $x1 || -z $x2 || -z $x3 ]]; then 
        echo "$DB_HOST is not a Microsoft.DBforMySQL/flexibleServers"
        return 1
    fi
    DB_HOST="$x1"; DB_HOST_FQDN="$x2"; DBA_USERNAME="$x3"; 
fi

echo "AZ mysql ${DB_HOST}: https://portal.azure.com/#@${az_tenantDefaultDomain}/resource/subscriptions/${az_id}/resourceGroups/${RG_NAME}/providers/Microsoft.DBforMySQL/flexibleServers/${DB_HOST}/overview"
echo ""

# #############################################################################

# Run firewall rules before coming here

echo -e "Creating permissive firewall rules if not exists"
echo -e "------------------------------------------------\n"

CMD_EXIT_ON_ERROR=PRINT_EXIT
cmd_mask_azure_secrets
CMD az mysql flexible-server firewall-rule list -n "${DB_HOST}" -g "${RG_NAME}"
python3 "${_LFC_REPO_ROOT}/utils/azure-sql-firewall-rule.py" \
    --kind mysql \
    --server "${DB_HOST}" \
    -g "${RG_NAME}" \
    --existing-rules "/tmp/az_stdout.$$" \
    --my-ip \
    --apply

echo -e "\nAZ mysql firewall-rule ${DB_HOST}: https://portal.azure.com/#@${az_tenantDefaultDomain}/resource/subscriptions/${az_id}/resourceGroups/${RG_NAME}/providers/Microsoft.DBforMySQL/flexibleServers/${DB_HOST}/networking \n"

# #############################################################################
# Check password

echo -e "\nValidate or reset root password.  Could take 5min if resetting"
echo -e   "--------------------------------------------------------------\n"

export DB_PASSWORD_CHANGED=""
if ! DB_USERNAME="$DBA_USERNAME" DB_PASSWORD="$DBA_PASSWORD" DB_CATALOG="mysql" TEST_DB_CONNECT; then
    if [[ -n "$DB_HOST_CREATED" ]]; then
        echo "can't connect to newly created host"
        cat /tmp/mysql_stdout.$$ /tmp/mysql_stderr.$$
        return 1
    fi

    password_reset_db

    DB_PASSWORD_CHANGED="1"
    if ! DB_USERNAME="$DBA_USERNAME" DB_PASSWORD="$DBA_PASSWORD" DB_CATALOG="mysql" TEST_DB_CONNECT; then
        cat /tmp/mysql_stdout.$$ /tmp/mysql_stderr.$$
        return 1
    fi
fi

# #############################################################################
# create catalog does not exist for MySQL


# #############################################################################
# set replication

echo -e "\nEnable binlog_row_image=full, binlog_format=row and require_secure_transport=off" 
echo -e   "--------------------------------------------------------------------------------\n"

_parm_args=()
CMD_EXIT_ON_ERROR=PRINT_EXIT
cmd_mask_azure_secrets
CMD_STDOUT=/tmp/az_parm_list.$$ CMD az mysql flexible-server parameter list --server-name "$DB_HOST"

# lakeflow connect
if [[ "on" == "$(jq -r '.[] | select(.name == "sql_generate_invisible_primary_key") | .currentValue | ascii_downcase' /tmp/az_parm_list.$$)" ]]; then
    _parm_args+=("sql_generate_invisible_primary_key=OFF")
fi

if [[ "full" != "$(jq -r '.[] | select(.name == "binlog_row_image") | .currentValue | ascii_downcase' /tmp/az_parm_list.$$)" ]]; then
    _parm_args+=("binlog_row_image=full")
fi

if [[ "row" != "$(jq -r '.[] | select(.name == "binlog_format") | .currentValue | ascii_downcase' /tmp/az_parm_list.$$)" ]]; then
    _parm_args+=("binlog_format=row")
fi

# lakeflow connect expects ssl disabled for now
if [[ "off" != "$(jq -r '.[] | select(.name == "require_secure_transport") | .currentValue | ascii_downcase' /tmp/az_parm_list.$$)" ]]; then
    _parm_args+=("require_secure_transport=off")
fi

if [[ 604800 -gt "$(jq -r '.[] | select(.name == "binlog_expire_logs_seconds") | .currentValue | ascii_downcase' /tmp/az_parm_list.$$)" ]]; then
    _parm_args+=("binlog_expire_logs_seconds=604800")
fi

# Azure Flex: log_output is FILE|NONE only (not TABLE / mysql.general_log).
if [[ "file" != "$(jq -r '.[] | select(.name == "log_output") | .currentValue | ascii_downcase' /tmp/az_parm_list.$$)" ]]; then
    _parm_args+=("log_output=FILE")
fi
_general_ro="$(jq -r '.[] | select(.name == "general_log") | .isReadOnly | ascii_downcase' /tmp/az_parm_list.$$)"
if [[ "${_general_ro}" != "true" ]] \
   && [[ "on" != "$(jq -r '.[] | select(.name == "general_log") | .currentValue | ascii_downcase' /tmp/az_parm_list.$$)" ]]; then
    _parm_args+=("general_log=ON")
elif [[ "${_general_ro}" == "true" ]]; then
    echo "general_log is read-only on this server version (e.g. 8.4); skipping. Use MYSQL_VERSION=5.7 on a new server if needed."
fi

if [[ "${#_parm_args[@]}" -gt 0 ]]; then
    CMD_EXIT_ON_ERROR=PRINT_EXIT
    cmd_mask_azure_secrets
    CMD az mysql flexible-server parameter set-batch \
      --server-name "$DB_HOST" \
      --resource-group "$RG_NAME" \
      --source "user-override" \
      --args "${_parm_args[@]}"

    # Restart only when Azure marks a changed param as pending restart or non-dynamic.
    CMD_EXIT_ON_ERROR=PRINT_EXIT
    cmd_mask_azure_secrets
    CMD_STDOUT=/tmp/az_parm_list.$$ CMD az mysql flexible-server parameter list --server-name "$DB_HOST"

    _need_restart=0
    for _arg in "${_parm_args[@]}"; do
        _pname="${_arg%%=*}"
        _pending="$(jq -r --arg n "$_pname" \
          '.[] | select(.name==$n) | .isConfigPendingRestart // empty' /tmp/az_parm_list.$$ \
          | tr '[:upper:]' '[:lower:]')"
        _dynamic="$(jq -r --arg n "$_pname" \
          '.[] | select(.name==$n) | .isDynamicConfig // empty' /tmp/az_parm_list.$$ \
          | tr '[:upper:]' '[:lower:]')"
        if [[ "$_pending" == "true" || "$_dynamic" == "false" ]]; then
            _need_restart=1
            echo "Parameter ${_pname} requires restart (isConfigPendingRestart=${_pending:-n/a} isDynamicConfig=${_dynamic:-n/a})"
            break
        fi
        if [[ -z "$_pending" && -z "$_dynamic" ]]; then
            _need_restart=1
            echo "Parameter ${_pname} has no restart metadata; restarting to be safe"
            break
        fi
    done

    if [[ "${_need_restart}" -eq 1 ]]; then
        CMD_EXIT_ON_ERROR=PRINT_EXIT
        cmd_mask_azure_secrets
        CMD az mysql flexible-server restart --name "$DB_HOST"
    else
        echo "All changed parameters are dynamic / not pending restart; skipping server restart"
    fi
fi

# #############################################################################
# save the credentials to secrets store for reuse

echo -e "\nSave secrets" 
echo -e   "------------\n"

# check return code instead of echo values
if should_save_secrets; then 
    put_secrets                         # bash export format
    put_secrets "${DB_HOST}" "json"     # json format for easier parsing
fi

# #############################################################################
echo -e "\nResource list"
echo -e   "-------------\n"

CMD_EXIT_ON_ERROR=
cmd_mask_azure_secrets
CMD az resource list --query "[?resourceGroup=='$RG_NAME'].{ name: name, flavor: kind, resourceType: type, region: location }" --output table
cat /tmp/az_stdout.$$

echo -e "\nServer logs (FILE; not mysql.general_log)"
echo -e   "----------------------------------------\n"
echo "  az mysql flexible-server server-logs list -g ${RG_NAME} -s ${DB_HOST} -o table"
echo "  az mysql flexible-server server-logs download -g ${RG_NAME} -s ${DB_HOST} -n <logfile>"
