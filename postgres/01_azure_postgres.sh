#!/usr/bin/env bash

# error out when undeclared variable is used
set -u 

# must be sourced for exports to continue to the next script
if [ "$0" == "$BASH_SOURCE" ]; then
  echo "Script is being executed directly. Please run as source $0"
  exit 1
fi

export DB_TYPE=postgres
export DB_SUFFIX=azure-pg
export CONNECTION_TYPE=POSTGRESQL
export SOURCE_TYPE=$CONNECTION_TYPE
export CLOUD_DB_TYPE=azure-pg

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
    PSQL "${@}"
}
export -f SQLCLI

SQLCLI_DBA() {
    DB_USERNAME="${DBA_USERNAME}" DB_PASSWORD="${DBA_PASSWORD}" PSQL "${@}"
}
export -f SQLCLI_DBA

SQLCLI_USER() {
    DB_USERNAME="${USER_USERNAME}" DB_PASSWORD="${USER_PASSWORD}" PSQL "${@}"
}
export -f SQLCLI_USER

password_reset_db() {
    CMD_EXIT_ON_ERROR=PRINT_EXIT
    cmd_mask_azure_secrets
    CMD az postgres flexible-server update -y -n "${DB_HOST}" --admin-password "${DBA_PASSWORD}" -g "${RG_NAME}"
}
export -f password_reset_db

delete_db() {
    CMD_EXIT_ON_ERROR=PRINT_EXIT
    cmd_mask_azure_secrets
    CMD az postgres flexible-server delete -y -n "${DB_HOST}" -g "${RG_NAME}"
}
export -f delete_db

firewall_rule_add() {
    # Thin wrapper: list current rules, then sync via utils/azure-sql-firewall-rule.py
    # Optional args are ignored; desired CIDRs come from DB_FIREWALL_CIDRS.
    local _lfc_root="${_LFC_REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
    CMD_EXIT_ON_ERROR=PRINT_EXIT
    cmd_mask_azure_secrets
    CMD az postgres flexible-server firewall-rule list --server-name "${DB_HOST}" -g "${RG_NAME}"
    python3 "${_lfc_root}/utils/azure-sql-firewall-rule.py" \
        --kind postgres \
        --server "${DB_HOST}" \
        -g "${RG_NAME}" \
        --existing-rules "/tmp/az_stdout.$$" \
        --my-ip \
        --apply
}
export -f firewall_rule_add

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
        perform pg_sleep(1);
    end loop;
end;
$$;
'
# below will fail on the gateway where the gateway waits for the commit to come
export sql_dml_generator_does_not_work_with_gateway='
set search_path='${DB_SCHEMA}';
do $$
declare 
    counter integer := 0;
begin
    while counter >= 0 loop
        -- intpk
        insert into intpk (dt) values (CURRENT_TIMESTAMP),(CURRENT_TIMESTAMP), (CURRENT_TIMESTAMP);
        delete from intpk where pk=(select min(pk) from intpk);
        update intpk set dt=CURRENT_TIMESTAMP where pk=(select min(pk) from intpk);
        -- dtix
        insert into dtix (dt) values (CURRENT_TIMESTAMP),(CURRENT_TIMESTAMP),(CURRENT_TIMESTAMP);
        -- wait
		raise notice '"'Counter %'"', counter;
	    counter := counter + 1;
        perform pg_sleep(1);
    end loop;
end;
commit;
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
if [[ -z "$DB_HOST" || "$DB_HOST_FQDN" != "$DB_HOST."* ]]; then
    cmd_mask_azure_secrets
    CMD_EXIT_ON_ERROR=
    if CMD az postgres flexible-server list -g "${RG_NAME}"; then
        read -rd "\n" x1 x2 x3 <<< "$(jq -r --arg suffix "-${DB_SUFFIX}" \
          'first(.[] | select(.fullyQualifiedDomainName!=null and .type=="Microsoft.DBforPostgreSQL/flexibleServers" and (.name | endswith($suffix)))) | .name, .fullyQualifiedDomainName, .administratorLogin' \
          /tmp/az_stdout.$$)"
        if [[ -n $x1 && -n $x2 && -n $x3 ]]; then 
            DB_HOST="$x1"; DB_HOST_FQDN="$x2"; DBA_USERNAME="$x3"; 
        fi
    fi
fi

# get avail catalog if not specified
if [[ -n "$DB_HOST" ]] && [[ -z "$DB_CATALOG" || "$DB_CATALOG" == "$CATALOG_BASENAME" ]]; then

    # check if secrets exists for this host
    if get_secrets "$DB_HOST"; then
        echo -e "\n USING VALUES FROM SECRETS \v"
    fi
fi

# secrets was empty or invalid.
if [[ -z "${DBA_USERNAME}" || -z "$DB_HOST" || "$DB_HOST" != *"-${DB_SUFFIX}" ]]; then 
    DB_HOST="${DB_BASENAME}-${DB_SUFFIX}"; 
fi  

if [[ -z "${DB_CATALOG}" || "$DB_CATALOG" == "$CATALOG_BASENAME" ]]; then 
    DB_CATALOG="${CATALOG_BASENAME}"
fi  

export DB_PORT=5432

# #############################################################################
# create sql server

echo -e "\nCreate database server if not exists"
echo -e   "------------------------------------\n"


export DB_HOST_CREATED=""
cmd_mask_azure_secrets
CMD_EXIT_ON_ERROR=
if ! CMD az postgres flexible-server show -n "${DB_HOST}" -g "${RG_NAME}"; then

    CMD_EXIT_ON_ERROR=PRINT_EXIT
    cmd_mask_azure_secrets
    CMD az provider register --wait --namespace Microsoft.DBforPostgreSQL

    # default catalog created
    # default Standard_B2s is the lowest allowed
    CMD_EXIT_ON_ERROR=PRINT_EXIT
    cmd_mask_azure_secrets
    if ! CMD az postgres flexible-server create -n "${DB_HOST}" -g "${RG_NAME}" \
        --tags "Owner=${DBX_USERNAME}" "${REMOVE_AFTER:+RemoveAfter=${REMOVE_AFTER}}" \
        --database "${DB_CATALOG}" \
        --version 17 \
        --node-count 1 \
        --public-access Enabled \
        --storage-size 32 \
        --tier Burstable \
        --sku-name Standard_B2s \
        --admin-user "${DBA_USERNAME}" \
        --admin-password "${DBA_PASSWORD}"; then
        return 1
    fi

    DB_HOST_CREATED="1"
    if [[ -n "$DELETE_DB_AFTER_SLEEP" ]]; then
        # </dev/null solves Fatal Python error: init_sys_streams: can't initialize sys standard streams
        nohup sleep "${DELETE_DB_AFTER_SLEEP}" && cmd_mask_azure_secrets && CMD az postgres flexible-server delete -y -n "${DB_HOST}" -g "${RG_NAME}" </dev/null >> ~/nohup.out 2>&1 &
        echo -e "\nDeleting ${DB_HOST} after ${DELETE_DB_AFTER_SLEEP}.  To cancel kill -9 $! \n" 
    fi

    read -rd "\n" x1 x2 <<< "$(jq -r 'select(.host!=null) | .host, .username' /tmp/az_stdout.$$)"
    DB_HOST_FQDN=$x1; DBA_USERNAME="$x2";
else
    read -rd "\n" x1 x2 x3 <<< "$(jq -r 'select(.fullyQualifiedDomainName!=null and .type=="Microsoft.DBforPostgreSQL/flexibleServers") | .name, .fullyQualifiedDomainName, .administratorLogin' /tmp/az_stdout.$$)"
    if [[ -z $x1 || -z $x2 || -z $x3 ]]; then 
        echo "$DB_HOST is not a Microsoft.DBforPostgreSQL/flexibleServers"
        return 1
    fi
    DB_HOST="$x1"; DB_HOST_FQDN="$x2"; DBA_USERNAME="$x3"; 
fi

echo "AZ postgres ${DB_HOST}: https://portal.azure.com/#@${az_tenantDefaultDomain}/resource/subscriptions/${az_id}/resourceGroups/${RG_NAME}/providers/Microsoft.DBforPostgreSQL/flexibleServers/${DB_HOST}/overview"
echo ""

# #############################################################################

# Run firewall rules before coming here

echo -e "Creating permissive firewall rules if not exists"
echo -e "------------------------------------------------\n"

CMD_EXIT_ON_ERROR=PRINT_EXIT
cmd_mask_azure_secrets
CMD az postgres flexible-server firewall-rule list --server-name "${DB_HOST}" -g "${RG_NAME}"
python3 "${_LFC_REPO_ROOT}/utils/azure-sql-firewall-rule.py" \
    --kind postgres \
    --server "${DB_HOST}" \
    -g "${RG_NAME}" \
    --existing-rules "/tmp/az_stdout.$$" \
    --my-ip \
    --apply

echo -e "\nAZ postgres firewall-rule ${DB_HOST}: https://portal.azure.com/#@${az_tenantDefaultDomain}/resource/subscriptions/${az_id}/resourceGroups/${RG_NAME}/providers/Microsoft.DBforPostgreSQL/flexibleServers/${DB_HOST}/networking \n"

# #############################################################################
# Check password

echo -e "\nValidate or reset root password.  Could take 5min if resetting"
echo -e   "--------------------------------------------------------------\n"

export DB_PASSWORD_CHANGED=""
if ! DB_USERNAME="$DBA_USERNAME" DB_PASSWORD="$DBA_PASSWORD" DB_CATALOG="postgres" TEST_DB_CONNECT; then
    if [[ -n "$DB_HOST_CREATED" ]]; then
        echo "can't connect to newly created host"
        cat /tmp/psql_stdout.$$ /tmp/psql_stderr.$$
        return 1
    fi

    password_reset_db

    DB_PASSWORD_CHANGED="1"
    if ! DB_USERNAME="$DBA_USERNAME" DB_PASSWORD="$DBA_PASSWORD" DB_CATALOG="postgres" TEST_DB_CONNECT; then
        cat /tmp/psql_stdout.$$ /tmp/psql_stderr.$$
        return 1
    fi
fi

# #############################################################################
# create catalog if not exists 

echo -e "\nCreate catalog if not exists" 
echo -e   "----------------------------\n"

# get avail catalog if not specified
DB_CATALOG="postgres" SQLCLI_DBA -c "select datname from pg_database where datname not in ('azure_maintenance', 'azure_sys', 'template0', 'template1', 'postgres');" </dev/null

# use existing catalog
if [[ -n "$DB_HOST" ]] && [[ -z "${DB_CATALOG}" || "$DB_CATALOG" == "${CATALOG_BASENAME}" ]] && grep -q "^${DB_CATALOG}$" /tmp/psql_stdout.$$ ; then 
    DB_CATALOG=$(cat /tmp/psql_stdout.$$)
fi 

# create if catalog does not exist
if ! grep -q "^$DB_CATALOG" /tmp/psql_stdout.$$; then
    DB_EXIT_ON_ERROR="PRINT_EXIT" DB_CATALOG="postgres" SQLCLI_DBA -c "create database ${DB_CATALOG};"
fi

# #############################################################################
# set replication

echo -e "\nEnable wal_level=logical and require_secure_transport=off" 
echo -e   "---------------------------------------------------------\n"

PARAMETER_SET=""
CMD_EXIT_ON_ERROR=PRINT_EXIT
cmd_mask_azure_secrets
CMD_STDOUT=/tmp/az_parm_list.$$ CMD az postgres flexible-server parameter list --server-name "$DB_HOST"

# cdc requires logical 
if [[ "logical" != "$(jq -r '.[] | select(.name == "wal_level") | .value | ascii_downcase' /tmp/az_parm_list.$$)" ]]; then
    CMD_EXIT_ON_ERROR=PRINT_EXIT
    cmd_mask_azure_secrets
    CMD az postgres flexible-server parameter set --server-name "$DB_HOST" --name  wal_level --value logical
    PARAMETER_SET="1"
fi

# lakeflow connect expects ssl disabled for now
if [[ "off" != "$(jq -r '.[] | select(.name == "require_secure_transport") | .value | ascii_downcase' /tmp/az_parm_list.$$)" ]]; then
    CMD_EXIT_ON_ERROR=PRINT_EXIT
    cmd_mask_azure_secrets
    CMD az postgres flexible-server parameter set --server-name "$DB_HOST" --name  require_secure_transport --value off
    PARAMETER_SET="1"
fi


# restart to take effect
if [[ "$PARAMETER_SET" == "1" ]]; then 
    CMD_EXIT_ON_ERROR=PRINT_EXIT
    cmd_mask_azure_secrets
    CMD az postgres flexible-server restart --name "$DB_HOST"
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

CMD_EXIT_ON_ERROR=
cmd_mask_azure_secrets
CMD az resource list --query "[?resourceGroup=='$RG_NAME'].{ name: name, flavor: kind, resourceType: type, region: location }" --output table
