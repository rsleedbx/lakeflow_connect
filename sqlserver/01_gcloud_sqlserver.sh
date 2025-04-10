#!/usr/bin/env bash

# error out when undeclared variable is used
set -u 

# must be sourced for exports to continue to the next script
if [ "$0" == "$BASH_SOURCE" ]; then
  echo "Script is being executed directly. Please run as source $0"
  exit 1
fi

export glcoud_database_version_ct=${glcoud_database_version:-SQLSERVER_2022_EXPRESS}
export glcoud_database_version_both=${glcoud_database_version:-SQLSERVER_2022_ENTERPRISE}
if [[ "${CDC_CT_MODE}" =~ ^(CT)$ ]]; then 
    export GCLOUD_DB_TYPE=gt
    export GCLOUD_DB_SUFFIX=gt
else
    export GCLOUD_DB_TYPE=gc
    export GCLOUD_DB_SUFFIX=gc
fi

DB_PORT=1433            # hardcoded by the cloud
DBA_USERNAME=sqlserver  # hardcoded by the cloud

# auto set the connection name
if [[ "${WHOAMI}" == "lfcddemo" ]] && [[ -z "${CONNECTION_NAME}" || "${CONNECTION_NAME}" != *"-${GCLOUD_DB_TYPE}" ]]; then
    CONNECTION_NAME="${WHOAMI}-${GCLOUD_DB_TYPE}"
    echo -e "\nChanging the connection nam\n"
    echo -e "CONNECTION_NAME=$CONNECTION_NAME"
fi

# #############################################################################
# export functions


# #############################################################################
# load secrets if exists


# #############################################################################
# set default host and catalog if not specified

echo -e "\nLoading available host and catalog if not specified \n"

# make host name follow the naming convention
if [[ -n "$DB_HOST" && "$DB_HOST" != *"-${GCLOUD_DB_SUFFIX}" ]]; then
    DB_HOST=""
    DB_HOST_FQDN=""
fi

# get avail sql server if not specified
if  [[ -z "$DB_HOST" ||  "$DB_HOST_FQDN" != "$DB_HOST."* ]]; then
    if [[ "${CDC_CT_MODE}" =~ ^(CT)$ ]]; then 
        GCLOUD sql instances list --filter "(databaseInstalledVersion ~ ^.*EXPRESS OR databaseInstalledVersion ~ ^.*WEB) AND name ~ ^${WHOAMI}-.*"
    else
        GCLOUD sql instances list --filter "(databaseInstalledVersion ~ ^.*ENTERPRISE OR databaseInstalledVersion ~ ^.*STANDARD) AND name ~ ^${WHOAMI}-.*"
    fi
    read -rd "\n" x1 x2 <<< "$(jq -r 'first( .[]) | .name, (.ipAddresses.[] | select(.type=="PRIMARY") | .ipAddress)' /tmp/gcloud_stdout.$$)"
    if [[ -n $x1 && -n $x2 ]]; then DB_HOST="$x1"; DB_HOST_FQDN="$x2"; fi
fi

# get avail catalog if not specified
if [[ -n "$DB_HOST" ]] && [[ -z "$DB_CATALOG" || "$DB_CATALOG" == "$CATALOG_BASENAME" ]]; then
    x1=""
    # check if secrets exists for this host
    if get_secrets $DB_HOST; then
    
        SQLCMD -d "master" -S "${DB_HOST_FQDN},${DB_PORT}" -U "${DBA_USERNAME}" -P "${DBA_PASSWORD}" \
            -C -l 10 -h -1 -Q "set nocount on; SELECT name FROM master.sys.databases WHERE name != N'master';"
        read -r x1 < /tmp/GCLOUD_stdout.$$
    fi

    if [[ -n $x1 ]]; then DB_CATALOG="$x1"; fi
fi

# secrets was empty or invalid.
if [[ -z "${DBA_USERNAME}" || -z "${DB_CATALOG}" || -z "$DB_HOST" || "$DB_HOST" != *"-${GCLOUD_DB_SUFFIX}" ]]; then 
    if [[ "${CDC_CT_MODE}" =~ ^(CT)$ ]]; then 
        DB_HOST="${WHOAMI}-${DB_BASENAME}-ct-${GCLOUD_DB_SUFFIX}"; 
    else
        DB_HOST="${WHOAMI}-${DB_BASENAME}-${GCLOUD_DB_SUFFIX}"; 
    fi
    DB_CATALOG="$CATALOG_BASENAME"
fi  

# #############################################################################
# create sql server

echo -e "\nCreate sql server if not exists\n"

# CT ONLY:    SQLSERVER_2022_EXPRESS ($0/hour DB license), SQLSERVER_2022_WEB ($0.05 DB/hour license), 
# CDC and CT: SQLSERVER_2022_STANDARD, SQLSERVER_2022_ENTERPRISE. ($0.50/hour DB license)
export DB_HOST_CREATED=""
if ! GCLOUD sql instances describe ${DB_HOST}; then

    if [[ "${CDC_CT_MODE}" =~ ^(CT)$  ]]; then 
        GCLOUD sql instances create ${DB_HOST} \
        --tags "owner=${DBX_USERNAME}","${REMOVE_AFTER:+removeafter=${REMOVE_AFTER}}" \
        ${CLOUD_LOCATION:+"--zone=$CLOUD_LOCATION"} \
        --edition=enterprise \
        --database-version=${glcoud_database_version_ct} \
        --cpu=1 \
        --memory=4GB \
        --zone=us-central1-a \
        --root-password "${DBA_PASSWORD}" \
        --no-backup \
        --no-deletion-protection
    else
        if [[ ${glcoud_database_version_both} == "*STANDARD" ]]; then
            GCLOUD sql instances create ${DB_HOST} \
            --tags "owner=${DBX_USERNAME}","${REMOVE_AFTER:+removeafter=${REMOVE_AFTER}}" \
            ${CLOUD_LOCATION:+"--zone=$CLOUD_LOCATION"} \
            --edition=enterprise \
            --database-version=${glcoud_database_version_both} \
            --cpu=1 \
            --memory=4GB \
            --zone=us-central1-a \
            --root-password "${DBA_PASSWORD}" \
            --no-backup \
            --no-deletion-protection
        else
            GCLOUD sql instances create ${DB_HOST} \
            ${CLOUD_LOCATION:+"--zone=$CLOUD_LOCATION"} \
            --tags "owner=${DBX_USERNAME}","${REMOVE_AFTER:+removeafter=${REMOVE_AFTER}}" \
            --edition=enterprise \
            --database-version=${glcoud_database_version_both} \
            --cpu=2 \
            --memory=8GB \
            --zone=us-central1-a \
            --root-password "${DBA_PASSWORD}" \
            --no-backup \
            --no-deletion-protection
        fi
        if [[ -b "$(cat /tmp/gcloud_stderr.$$ | grep ERROR)" ]]; then
                cat /tmp/gcloud_stderr.$$
                return 1
        fi
    fi
    DB_HOST_CREATED="1"
    if [[ -n "$DELETE_DB_AFTER_SLEEP" ]]; then
        # </dev/null solves Fatal Python error: init_sys_streams: can't initialize sys standard streams
        nohup sleep "${DELETE_DB_AFTER_SLEEP}" && GCLOUD sql instances delete ${DB_HOST:-${DB_BASENAME}} </dev/null >> ~/nohup.out 2>&1 &
        echo -e "\nDeleting sqlserver ${DB_HOST} after ${DELETE_DB_AFTER_SLEEP}.  To cancel kill -9 $! \n" 
    fi
fi
read -rd "\n" x1 x2 <<< "$(jq -r '.name, (.ipAddresses.[] | select(.type=="PRIMARY") | .ipAddress)' /tmp/gcloud_stdout.$$)"
if [[ -z $x1 || -z $x2 ]]; then 
    echo "$DB_HOST does not have .ipAddress"
    return 1
fi
DB_HOST=${x1}
DB_HOST_FQDN=${x2}

echo -e "gcloud sql ${DB_HOST}: https://console.cloud.google.com/sql/instances/${DB_HOST} \n"

# #############################################################################

echo -e "Creating permissive firewall rules if not exists\n"

# convert CIDR to range 

firewall_set() {
    printf -v DB_FIREWALL_CIDRS_CSV '%s,' "${DB_FIREWALL_CIDRS[@]}"
    DB_FIREWALL_CIDRS_CSV="${DB_FIREWALL_CIDRS_CSV%,}"  # remove trailing ,
    if ! GCLOUD sql instances patch "${DB_HOST}" --authorized-networks="${DB_FIREWALL_CIDRS_CSV}"; then
        cat /tmp/gcloud_stderr.$$
        return 1
    fi
}

if (( "$(jq '.settings.ipConfiguration.authorizedNetworks | length' /tmp/gcloud_stdout.$$)" == 0 )); then 
    if ! firewall_set; then return 1; fi
fi

echo "gcloud connections ${DB_HOST}: https://console.cloud.google.com/sql/instances/${DB_HOST}/connections/summary"

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
        cat /tmp/GCLOUD_stderr.$$; return 1;
    fi
fi

# #############################################################################
# create catalog if not exists 

echo -e "\nCreate catalog if not exists\n" 

SQLCMD -d "master" -S "${DB_HOST_FQDN},${DB_PORT}" -U "${DBA_USERNAME}" -P "${DBA_PASSWORD}" \
    -C -l 10 -h -1 -l 60 -Q "set nocount on; SELECT name FROM master.sys.databases WHERE name = N'${DB_CATALOG}';"
if [[ ! -s /tmp/sqlcmd_stdout.$$ && ! -s /tmp/sqlcmd_stderr.$$ ]]; then
    SQLCMD -d "master" -S "${DB_HOST_FQDN},${DB_PORT}" -U "${DBA_USERNAME}" -P "${DBA_PASSWORD}" \
        -C -l 10 -h -1 -Q "create database [${DB_CATALOG}];"
    if [[ -s /tmp/sqlcmd_stdout.$$ || -s /tmp/sqlcmd_stderr.$$ ]]; then
        cat /tmp/sqlcmd_stdout.$$ /tmp/sqlcmd_stderr.$$
        return 1
    fi
fi

# #############################################################################
# save the credentials to secrets store for reuse

if [[ -z "$DELETE_DB_AFTER_SLEEP" ]] && [[ "${DB_HOST_CREATED}" == "1" || "${DB_PASSWORD_CHANGED}" == "1" ]]; then
    put_secrets
fi

# #############################################################################