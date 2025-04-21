#!/usr/bin/env bash

# error out when undeclared variable is used
set -u 

# must be sourced for exports to continue to the next script
if [ "$0" == "$BASH_SOURCE" ]; then
  echo "Script is being executed directly. Please run as source $0"
  exit 1
fi

export DB_TYPE=zp
export DB_SUFFIX=zp
export CONNECTION_TYPE=POSTGRESQL
export SOURCE_TYPE=$CONNECTION_TYPE

# auto set the connection name
if [[ "${WHOAMI}" == "lfcddemo" ]] && [[ -z "${CONNECTION_NAME}" || "${CONNECTION_NAME}" != *"-${DB_TYPE}" ]]; then
    CONNECTION_NAME="${WHOAMI}-${DB_TYPE}"
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

SQLCLI() {
    local DB_USERNAME=${DB_USERNAME:-${USER_USERNAME}}
    local DB_PASSWORD=${DB_PASSWORD:-${USER_PASSWORD}}
    local DB_HOST_FQDN=${DB_HOST_FQDN}
    local DB_PORT=${DB_PORT:-${1433}}
    local DB_CATALOG=${DB_CATALOG:-"postgres"}
    local DB_LOGIN_TIMEOUT=${DB_LOGIN_TIMEOUT:-10}
    local DB_SSLMODE=${DB_SSLMODE:-"allow"}
    local DB_URL=${DB_URL:-""}
    local DB_EXIT_ON_ERROR=${DB_EXIT_ON_ERROR:-""}
    # stdout and stderr file names
    local DB_OUT_SUFFIX=${DB_OUT_SUFFIX:-""}
    local DB_STDOUT=${DB_STDOUT:-"/tmp/psql_stdout${DB_OUT_SUFFIX:+_${DB_OUT_SUFFIX}}.$$"}
    local DB_STDERR=${DB_STDERR:-"/tmp/psql_stderr${DB_OUT_SUFFIX:+_${DB_OUT_SUFFIX}}.$$"}

    PWMASK="${*}"
    PWMASK="${PWMASK//$DBA_PASSWORD/\$DBA_PASSWORD}"
    PWMASK="${PWMASK//$USER_PASSWORD/\$USER_PASSWORD}"
    PWMASK="${PWMASK//$DBX_USERNAME/\$DBX_USERNAME}"
    PWMASK="${PWMASK//$DBA_USERNAME/\$DBA_USERNAME}"
    PWMASK="${PWMASK//$USER_USERNAME/\$USER_USERNAME}"
    PWMASK="${PWMASK//$DB_CATALOG/\$DB_CATALOG}"

    echo psql "${DB_USERNAME}:/${DB_CATALOG}" "${PWMASK}" 

    export PGPASSWORD=$DB_PASSWORD
    export PGCONNECT_TIMEOUT=$DB_LOGIN_TIMEOUT
    if [[ -t 0 ]]; then
        # stdin is attached
        psql "postgresql://${DB_USERNAME}@${DB_HOST_FQDN}:${DB_PORT}/${DB_CATALOG}?sslmode=${DB_SSLMODE}" "${@}" 
    else
        # running in batch mode
        psql "postgresql://${DB_USERNAME}@${DB_HOST_FQDN}:${DB_PORT}/${DB_CATALOG}?sslmode=${DB_SSLMODE}" -q --csv --tuples-only "${@}" >${DB_STDOUT} 2>${DB_STDERR} 
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
    DB_USERNAME="${DBA_USERNAME}" DB_PASSWORD="${DBA_PASSWORD}" SQLCLI "${@}"
}
export -f SQLCLI_DBA

SQLCLI_USER() {
    DB_USERNAME="${USER_USERNAME}" DB_PASSWORD="${USER_PASSWORD}" SQLCLI "${@}"
}
export -f SQLCLI_USER

test_db_connect() {
    SQLCLI "$@" -c "select 1" </dev/null
    RC=$?
    if [[ $RC == 0 ]]; then 
        echo "connect ok $DB_USERNAME@$DB_HOST_FQDN:${DB_PORT}/${DB_CATALOG}"
    fi
    return $RC
}

password_reset_db() {
    if ! AZ postgres flexible-server update -y -n "${DB_HOST}" --admin-password "${DBA_PASSWORD}" -g "${RG_NAME}"; then
        cat /tmp/az_stderr.$$; return 1;
    fi
}
export -f password_reset_db


delete_db() {
    if ! AZ postgres flexible-server delete -y -n "${DB_HOST}" -g "${RG_NAME}"; then 
        cat /tmp/az_stderr.$$; return 1;
    fi
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
    if ! AZ  postgres flexible-server firewall-rule show --rule-name "${fw_rule_name}" --name "${DB_HOST}" -g "${RG_NAME}"; then
        if ! AZ postgres flexible-server firewall-rule create --rule-name "${fw_rule_name}" --name "$DB_HOST" -g "${RG_NAME}" --start-ip-address "${host_min}" --end-ip-address "${host_max}"; then
            cat /tmp/az_stderr.$$; return 1;
        fi
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
        perform pg_sleep(1);
    end loop;
end;
$$;
'
# will below fail?
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
if  [[ -z "$DB_HOST" ||  "$DB_HOST_FQDN" != "$DB_HOST."* ]] && \
    AZ postgres flexible-server list -g "${RG_NAME}"; then
    
    read -rd "\n" x1 x2 x3 <<< "$(jq -r 'first(.[] | select(.fullyQualifiedDomainName!=null and .type=="Microsoft.DBforPostgreSQL/flexibleServers")) | .name, .fullyQualifiedDomainName, .administratorLogin' /tmp/az_stdout.$$)"
    if [[ -n $x1 && -n $x2 && -n $x3 && "$x1" == *"-${DB_SUFFIX}" ]]; then 
        DB_HOST="$x1"; DB_HOST_FQDN="$x2"; DBA_USERNAME="$x3"; 
    fi
fi

# get avail catalog if not specified
if [[ -n "$DB_HOST" ]] && [[ -z "$DB_CATALOG" || "$DB_CATALOG" == "$CATALOG_BASENAME" ]]; then

    # check if secrets exists for this host
    if get_secrets $DB_HOST; then
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
if ! AZ postgres flexible-server show -n "${DB_HOST}" -g "${RG_NAME}"; then
    # sql server create does not support tags
    if ! AZ postgres flexible-server create -n "${DB_HOST}" -g "${RG_NAME}" \
        --tags "Owner=${DBX_USERNAME}" "${REMOVE_AFTER:+RemoveAfter=${REMOVE_AFTER}}" \
        --database ${DB_CATALOG} \
        --node-count 1 \
        --public-access Enabled \
        --storage-size 32 \
        --version 16 \
        --tier Burstable \
        --sku-name standard_b2s \
        --admin-user "${DBA_USERNAME}" \
        --admin-password "${DBA_PASSWORD}"; then
        cat /tmp/az_stderr.$$; return 1;
    fi
    DB_HOST_CREATED="1"
    if [[ -n "$DELETE_DB_AFTER_SLEEP" ]]; then
        # </dev/null solves Fatal Python error: init_sys_streams: can't initialize sys standard streams
        nohup sleep "${DELETE_DB_AFTER_SLEEP}" && AZ postgres flexible-server delete -y -n "${DB_HOST}" -g "${RG_NAME}" </dev/null >> ~/nohup.out 2>&1 &
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

# convert CIDR to range 

if ! AZ postgres flexible-server firewall-rule list -n "${DB_HOST}" -g "${RG_NAME}"; then cat /tmp/az_stdout.$$ /tmp/az_stderr.$$; return 1; fi
if [[ "0" == "$(jq length /tmp/az_stdout.$$)" ]]; then
    firewall_rule_add "${DB_FIREWALL_CIDRS[@]}"
fi

echo -e "\nAZ sql server firewall-rule ${DB_HOST}: https://portal.azure.com/#@${az_tenantDefaultDomain}/resource/subscriptions/${az_id}/resourceGroups/${RG_NAME}/providers/Microsoft.DBforPostgreSQL/flexibleServers/${DB_HOST}/networking \n"

# #############################################################################
# Check password

echo -e "\nValidate or reset root password.  Could take 5min if resetting"
echo -e   "--------------------------------------------------------------\n"


export DB_PASSWORD_CHANGED=""
if ! DB_USERNAME="$DBA_USERNAME" DB_PASSWORD="$DBA_PASSWORD" DB_CATALOG="postgres" test_db_connect; then
    if [[ -n "$DB_HOST_CREATED" ]]; then
        echo "can't connect to newly created host"
        cat /tmp/psql_stdout.$$ /tmp/psql_stderr.$$; return 1;
    fi

    password_reset_db

    DB_PASSWORD_CHANGED="1"
    if ! DB_USERNAME="$DBA_USERNAME" DB_PASSWORD="$DBA_PASSWORD" DB_CATALOG="postgres" test_db_connect; then
        cat /tmp/psql_stdout.$$ /tmp/psql_stderr.$$; return 1;
    fi
fi

# #############################################################################
# create catalog if not exists 

echo -e "\nCreate catalog if not exists" 
echo -e   "----------------------------\n"

# get avail catalog if not specified
DB_CATALOG="postgres" SQLCLI_DBA -c "select datname from pg_database where datname not in ('azure_maintenance', 'template0', 'template1', 'postgres', 'azure_sys', 'template0');" </dev/null

# use existing catalog
if [[ -n "$DB_HOST" ]] && [[ -z "${DB_CATALOG}" || "$DB_CATALOG" == "${CATALOG_BASENAME}" ]] && grep -q "^${DB_CATALOG}$" /tmp/psql_stdout.$$ ; then 
    DB_CATALOG=$(cat /tmp/psql_stdout.$$)
fi 

# create if catalog does not exist
if ! grep -q "^$DB_CATALOG" /tmp/psql_stdout.$$; then
    DB_EXIT_ON_ERROR="PRINT_EXIT" DB_CATALOG="postgres" SQLCLI_DBA -c "create database ${DB_CATALOG};"
fi

# #############################################################################
# create catalog if not exists 

echo -e "\nEnable wal_level=logical and require_secure_transport=off" 
echo -e   "---------------------------------------------------------\n"

PARAMETER_SET=""
# lakeflow connect 
if AZ postgres flexible-server parameter show --server-name $DB_HOST --name  wal_level; then
    if [[ "logical" != "$(jq -r ".value" /tmp/az_stdout.$$)" ]]; then
        if  ! AZ postgres flexible-server parameter set --server-name $DB_HOST --name  wal_level --value logical; then 
            cat /tmp/az_stdout.$$ /tmp/az_stderr.$$; return 1;
        fi
        PARAMETER_SET="1"
    fi
fi

# lakeflow connect expects ssl disabled for now
if AZ postgres flexible-server parameter show --server-name $DB_HOST --name  require_secure_transport ; then
    if [[ "off" != "$(jq -r ".value" /tmp/az_stdout.$$)" ]]; then
        if ! AZ postgres flexible-server parameter set --server-name $DB_HOST --name  require_secure_transport --value off; then
            cat /tmp/psql_stdout.$$ /tmp/psql_stderr.$$; return 1;
        fi
        PARAMETER_SET="1"
    fi
fi

# restart to take effect
if [[ "$PARAMETER_SET" == "1" ]] && ! AZ postgres flexible-server restart --name $DB_HOST; then 
    cat /tmp/psql_stdout.$$ /tmp/psql_stderr.$$; return 1;
fi

# #############################################################################
# save the credentials to secrets store for reuse

if [[ -z "$DELETE_DB_AFTER_SLEEP" ]] && [[ "${DB_HOST_CREATED}" == "1" || "${DB_PASSWORD_CHANGED}" == "1" ]]; then 
    echo "writing secrets create database that won't be deleted"
    put_secrets
elif [[  "${SECRETS_RETRIEVED}" == '1' && "${DB_PASSWORD_CHANGED}" == "1" ]] ; then
    echo "writing secrets for existing database with new a DBA password"
    put_secrets
fi

# #############################################################################
echo -e "\nBilling ${RG_NAME}: https://portal.azure.com/#@${az_tenantDefaultDomain}/resource/subscriptions/${az_id}/resourceGroups/${RG_NAME}/costanalysis"
echo "Resource list"

az resource list --query "[?resourceGroup=='$RG_NAME'].{ name: name, flavor: kind, resourceType: type, region: location }" --output table
