#!/usr/bin/env bash

# remove using cloud scheduler
export REMOVE_AFTER=$(date --date='+0 day' +%Y-%m-%d)

# stop after sleep locally
export STOP_AFTER_SLEEP=${STOP_AFTER_SLEEP:-"20m"}

# uncomment if delete is also desired. 
# delete after sleep locally  
# export DELETE_AFTER_SLEEP=${DELETE_AFTER_SLEEP:-"120m"}

export CLOUD_LOCATION="${CLOUD_LOCATION:-"East US"}"
export WHOAMI=${WHOAMI:-$(whoami | tr -d .)}

export DBX_USERNAME=${DBX_USERNAME:-$(databricks current-user me | jq -r .userName)}
export DB_CATALOG=${DB_CATALOG:-${WHOAMI}}
export DB_SCHEMA=${DB_SCHEMA:-${WHOAMI}}
export DB_PORT=${DB_PORT:-1433}

export DBA_USERNAME=${DBA_USERNAME:-sqlserver}    # GCP defaults to sqlserver.  Make it same for Azure
export USER_USERNAME=${USER_USERNAME:-${WHOAMI}}  # set if not defined

# prefer az sql server if exists
if [[ -z "$AZ_DB_TYPE" ]] || [[ "$AZ_DB_TYPE" == "zsql" ]]; then
    echo "az sql server list"
    export DB_HOST=$(az sql server list --output json 2>/tmp/az_stderr.$$ | tee /tmp/az_stdout.$$ | jq -r .[].name)
    if [[ -n "${DB_HOST}" ]]; then 
        DB_HOST_FQDN=$(az sql server show --name $DB_HOST 2>/dev/null | jq -r .fullyQualifiedDomainName)
        export DB_HOST_FQDN
        DB_PORT=1433
        export DB_PORT
        echo "az sql server list: using $DB_HOST $DB_HOST_FQDN $DB_PORT"
    fi
fi

# check az sql mi if exists
if [[ -z "$AZ_DB_TYPE" ]] || [[ "$AZ_DB_TYPE" == "zmi" ]]; then
    if [[ -z $DB_HOST ]]; then 
        echo "az sql mi list"
        export DB_HOST=$(az sql mi list --output json 2>/tmp/az_stderr.$$ | tee /tmp/az_stdout.$$ | jq -r .[].name)
        DB_HOST_FQDN=$(cat /tmp/az_stdout.$$ | jq -r .[].fullyQualifiedDomainName | sed "s/^${DB_HOST}\./${DB_HOST}\.public\./g")
        export DB_HOST_FQDN
        DB_PORT=3342
        export DB_PORT
        echo "az sql mi list: using $DB_HOST $DB_HOST_FQDN $DB_PORT"
    fi
fi

# will be creating a new host.  get a random
if [[ -z $DB_HOST ]]; then 
    export DB_BASENAME=${DB_HOST:-$(pwgen -1AB 8)}        # lower case, name seen on internet
    export DB_HOST=${DB_BASENAME}
fi
export SECRETS_SCOPE="${WHOAMI}_${DB_HOST}"

# set or use existing DBA_PASSWORD
export DBA_PASSWORD="$(databricks secrets get-secret ${SECRETS_SCOPE} DBA_PASSWORD 2>/dev/null | jq -r .value | base64 --decode)"
if [[ -z "$DBA_PASSWORD" ]]; then 
    export DBA_PASSWORD="${DBA_PASSWORD:-$(pwgen -1y 32)}"  # set if not defined
fi

# set or use existing USER_PASSWORD
export USER_PASSWORD=$(databricks secrets get-secret ${SECRETS_SCOPE} USER_PASSWORD 2>/dev/null | jq -r .value | base64 --decode)
if [[ -z $USER_PASSWORD ]]; then 
    export USER_PASSWORD=${USER_PASSWORD:-$(pwgen -1y 32)}  # set if not defined
fi  