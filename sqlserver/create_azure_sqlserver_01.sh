export DBX_USERNAME=${DBX_USERNAME:-$(databricks current-user me | jq -r .userName)}
export WHOAMI=${WHOAMI:-$(whoami | tr -d .)}
export EXPIRE_DATE=$(date --date='+2 day' +%Y-%m-%d)
export DB_CATALOG=${DB_CATALOG:-${WHOAMI}}
export DB_SCHEMA=${DB_SCHEMA:-${WHOAMI}}
export DB_PORT=${DB_PORT:-1433}
export DBA_USERNAME=${DBA_USERNAME:-sqlserver}    # GCP defaults to sqlserver.  Make it same for Azure
export USER_USERNAME=${USER_USERNAME:-${WHOAMI}}  # set if not defined
# set or use existing DB_HOST and DB_HOST_FQDN (dns or IP)
export DB_HOST=$(az sql server list --output json | jq -r .[].name)
if [[ -z $DB_HOST ]]; then 
  export DB_HOST=${DB_HOST:-$(pwgen -1AB 8)}        # lower case, name seen on internet
fi
export DB_HOST_FQDN=$(az sql server show --name $DB_HOST 2>/dev/null | jq -r .fullyQualifiedDomainName)
echo "DB_HOST: $DB_HOST"
# set or use existing DBA_PASSWORD
export DBA_PASSWORD=$(databricks secrets get-secret ${WHOAMI}_${DB_HOST} DBA_PASSWORD 2>/dev/null | jq -r .value)
DBA_PASSWORD_RESET=""
if [[ -z $DBA_PASSWORD ]]; then 
  export DBA_PASSWORD=${DBA_PASSWORD:-$(pwgen -1B 32)}  # set if not defined
  databricks secrets create-scope ${WHOAMI}_${DB_HOST} 2>/dev/null 
  databricks secrets put-secret ${WHOAMI}_${DB_HOST} DBA_PASSWORD --string-value ${DBA_PASSWORD}  
  if [[ -n $DB_HOST_FQDN ]]; then export DBA_PASSWORD_RESET=1; fi
fi
# set or use existing USER_PASSWORD
export USER_PASSWORD=$(databricks secrets get-secret ${WHOAMI}_${DB_HOST} USER_PASSWORD 2>/dev/null | jq -r .value)
USER_PASSWORD_RESET=""
if [[ -z $USER_PASSWORD ]]; then 
  export USER_PASSWORD=${USER_PASSWORD:-$(pwgen -1B 32)}  # set if not defined
  databricks secrets create-scope ${WHOAMI}_${DB_HOST} 2>/dev/null  
  databricks secrets put-secret ${WHOAMI}_${DB_HOST} USER_PASSWORD --string-value ${USER_PASSWORD}   
  if [[ -n $DB_HOST_FQDN ]]; then export USER_PASSWORD_RESET=1; fi
fi  
# DBA password reset on the master
if [[ -n $DB_HOST_FQDN ]] && [[ -z $(echo "select 1" | sqlcmd -S $DB_HOST_FQDN,${DB_PORT} -U $DBA_USERNAME -P $DBA_PASSWORD -C -l 60) ]]; then 
  az sql server update --name ${DB_HOST} --admin-password "${DBA_PASSWORD}"
  echo "$DB_HOST: DBA_PASSWORD_RESET with $DBA_PASSWORD"
fi
# User password reset on the master
if [[ -n $DB_HOST_FQDN ]] && [[ -z $(echo "select 1" | sqlcmd -d $DB_CATALOG -S ${DB_HOST_FQDN},${DB_PORT} -U "${USER_USERNAME}" -P "${USER_PASSWORD}" -C -l 60) ]]; then
  echo "alter login ${USER_USERNAME} with password = '${USER_PASSWORD}'" | sqlcmd -S ${DB_HOST_FQDN},${DB_PORT} -U "${DBA_USERNAME}" -P "${DBA_PASSWORD}" -C -l 60
  echo "$DB_HOST: USER_PASSWORD with $USER_PASSWORD"
fi