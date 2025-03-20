#!/usr/bin/env bash

export REMOVE_AFTER=$(date --date='+0 day' +%Y-%m-%d)

export CLOUD_LOCATION="${CLOUD_LOCATION:-"East US"}"
export WHOAMI=${WHOAMI:-$(whoami | tr -d .)}

export DBX_USERNAME=${DBX_USERNAME:-$(databricks current-user me | jq -r .userName)}
export DB_CATALOG=${DB_CATALOG:-${WHOAMI}}
export DB_SCHEMA=${DB_SCHEMA:-${WHOAMI}}
export DB_PORT=${DB_PORT:-1433}

export DBA_USERNAME=${DBA_USERNAME:-sqlserver}    # GCP defaults to sqlserver.  Make it same for Azure
export USER_USERNAME=${USER_USERNAME:-${WHOAMI}}  # set if not defined

# set or use existing DB_HOST and DB_HOST_FQDN (dns or IP)
export DB_HOST=$(az sql server list --output json 2>/dev/null | jq -r .[].name)
if [[ -z $DB_HOST ]]; then 
  export DB_HOST=${DB_HOST:-$(pwgen -1AB 8)}        # lower case, name seen on internet
fi
export DB_HOST_FQDN=$(az sql server show --name $DB_HOST 2>/dev/null | jq -r .fullyQualifiedDomainName)
if [[ -n "${DB_HOST_FQDN}" ]]; then echo "DB_HOST: $DB_HOST"; fi

export SECRETS_SCOPE="${WHOAMI}_${DB_HOST}"

# set or use existing DBA_PASSWORD
export DBA_PASSWORD="$(databricks secrets get-secret ${SECRETS_SCOPE} DBA_PASSWORD 2>/dev/null | jq -r .value | base64 --decode)"
DBA_PASSWORD_RESET=""
if [[ -z "$DBA_PASSWORD" ]]; then 
    export DBA_PASSWORD="${DBA_PASSWORD:-$(pwgen -1B 32)}"  # set if not defined
    if [[ -n $DB_HOST_FQDN ]]; then 
        export DBA_PASSWORD_RESET=1; 
        databricks secrets create-scope ${SECRETS_SCOPE} 2>/dev/null 
        databricks secrets put-secret ${SECRETS_SCOPE} DBA_PASSWORD --string-value "${DBA_PASSWORD}"
    fi
fi

# set or use existing USER_PASSWORD
export USER_PASSWORD=$(databricks secrets get-secret ${SECRETS_SCOPE} USER_PASSWORD 2>/dev/null | jq -r .value | base64 --decode)
USER_PASSWORD_RESET=""
if [[ -z $USER_PASSWORD ]]; then 
    export USER_PASSWORD=${USER_PASSWORD:-$(pwgen -1B 32)}  # set if not defined
    if [[ -n $DB_HOST_FQDN ]]; then 
        export USER_PASSWORD_RESET=1
        databricks secrets create-scope ${SECRETS_SCOPE} 2>/dev/null  
        databricks secrets put-secret ${SECRETS_SCOPE} USER_PASSWORD --string-value "${USER_PASSWORD}"
    fi
fi  

# DBA password reset on the master if the current password not work
if [[ -n "$DB_HOST_FQDN" ]] && [[ -z "$(echo "select 1" | sqlcmd -S $DB_HOST_FQDN,${DB_PORT} -U $DBA_USERNAME -P $DBA_PASSWORD -C -l 60)" ]]; then 
    az_sql_server_update_output="$(az sql server update --name ${DB_HOST} --admin-password "${DBA_PASSWORD}")"
    sqlcmd_select1_output="$(echo "select 1" | sqlcmd -S $DB_HOST_FQDN,${DB_PORT} -U $DBA_USERNAME -P $DBA_PASSWORD -C -l 60)"
    export sqlcmd_select1_output
    if [[ -n "$sqlcmd_select1_output" ]]; then
    echo "$DB_HOST: DBA_PASSWORD_RESET with $DBA_PASSWORD"
    else
        echo "Error: DBA_PASSWORD_RESET failed $DBA_PASSWORD"
    fi
fi

# user password reset on the master if the current password not work
if [[ -n "$DB_HOST_FQDN" ]] && [[ -z "$(echo "select 1" | sqlcmd -S $DB_HOST_FQDN,${DB_PORT} -U $USER_USERNAME -P $USER_PASSWORD -C -l 60)" ]]; then 
    cat <<EOF | sqlcmd -S ${DB_HOST_FQDN},${DB_PORT} -U "${DBA_USERNAME}" -P "${DBA_PASSWORD}" -C -l 60 -e
    CREATE LOGIN ${USER_USERNAME} WITH PASSWORD = '${USER_PASSWORD}'
    go
    alter login ${USER_USERNAME} with password = '${USER_PASSWORD}'
    go
    -- gcp does not allow user login
    CREATE USER ${USER_USERNAME} FOR LOGIN ${USER_USERNAME} WITH DEFAULT_SCHEMA=dbo
    go
EOF
    sqlcmd_select1_output="$(echo "select 1" | sqlcmd -S $DB_HOST_FQDN,${DB_PORT} -U $USER_USERNAME -P $USER_PASSWORD -C -l 60)"
    export sqlcmd_select1_output
    if [[ -n "$sqlcmd_select1_output" ]]; then
    echo "$DB_HOST: USER_PASSWORD_RESET with $USER_PASSWORD"
    else
        echo "Error: USER_PASSWORD_RESET failed $USER_PASSWORD"
    fi
fi
