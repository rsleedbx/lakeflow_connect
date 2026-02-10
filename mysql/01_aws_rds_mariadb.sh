#!/usr/bin/env bash

# error out when undeclared variable is used
set -u

# must be sourced for exports to continue to the next script
if [ "$0" == "${BASH_SOURCE[0]}" ]; then
  echo "Script is being executed directly. Please run as source $0"
  exit 1
fi

export MARIADB_ENGINE_VERSION=${MARIADB_ENGINE_VERSION:-10.11}
export CLOUD_DB_TYPE=aws-rds-mariadb
export CLOUD_DB_SUFFIX=aws-rds-mariadb
export CONNECTION_TYPE=MARIADB
export SOURCE_TYPE=$CONNECTION_TYPE

DB_PORT=3306
DB_SG_NAME="${WHOAMI}-3306-sg"
DB_SG_ID=""

# #############################################################################
# set sqlcli to mysql client

SQLCLI() {
    DB_USERNAME="${USER_USERNAME}" DB_PASSWORD="${USER_PASSWORD}" DB_CATALOG="${DB_CATALOG:-$DB_SCHEMA}" MYSQLCLI "${@}"
}
export -f SQLCLI

SQLCLI_DBA() {
    DB_USERNAME="${DBA_USERNAME}" DB_PASSWORD="${DBA_PASSWORD}" DB_CATALOG="${DB_CATALOG:-mysql}" MYSQLCLI "${@}"
}
export -f SQLCLI_DBA

SQLCLI_USER() {
    DB_USERNAME="${USER_USERNAME}" DB_PASSWORD="${USER_PASSWORD}" DB_CATALOG="${DB_CATALOG:-$DB_SCHEMA}" MYSQLCLI "${@}"
}
export -f SQLCLI_USER

password_reset_db() {
    DB_EXIT_ON_ERROR="PRINT_EXIT" AWS rds modify-db-instance \
        --db-instance-identifier "$DB_HOST" \
        --master-user-password "$DBA_PASSWORD" \
        --apply-immediately
}
export -f password_reset_db

delete_db() {
    DB_EXIT_ON_ERROR="PRINT_EXIT" AWS rds delete-db-instance \
        --db-instance-identifier "$DB_HOST" \
        --skip-final-snapshot
}
export -f delete_db

# #############################################################################
# init cloud

AWS_INIT

# #############################################################################
# use default or from the secrets

if [[ -z "${DBA_USERNAME}" || -z "$DB_HOST" || "$DB_HOST" == "${DB_BASENAME}" || "$DB_HOST" != *"-${CLOUD_DB_SUFFIX}" ]]; then
    DB_HOST="${DB_BASENAME}-${CLOUD_DB_SUFFIX}"
fi

if [[ -z "${DB_CATALOG}" ]]; then
    DB_CATALOG="$CATALOG_BASENAME"
fi

# #############################################################################
# create MariaDB RDS instance

echo -e "\nCreate MariaDB RDS instance if not exists (about 5 mins to create)"
echo -e   "-------------------------------------------------------------------\n"

export DB_HOST_CREATED=""

if ! AWS rds describe-db-instances \
    --db-instance-identifier "$DB_HOST" \
    ; then

    DB_EXIT_ON_ERROR="PRINT_EXIT" AWS rds create-db-instance \
        --tags "Key=Owner,Value=${DBX_USERNAME}" "${REMOVE_AFTER:+Key=RemoveAfter,Value=${REMOVE_AFTER}}" "Key=AllowDowntime,Value=off" "Key=KeepAlive,Value=True" \
        --db-instance-identifier "$DB_HOST" \
        --db-name "$DB_CATALOG" \
        --db-instance-class db.t3.micro \
        --engine mariadb \
        --engine-version "$MARIADB_ENGINE_VERSION" \
        --no-auto-minor-version-upgrade \
        --master-username "$DBA_USERNAME" \
        --master-user-password "$DBA_PASSWORD" \
        --allocated-storage 20 \
        --backup-retention-period 0 \
        ${DB_SG_ID:+--vpc-security-group-ids "$DB_SG_ID"}

    DB_EXIT_ON_ERROR="PRINT_EXIT" DB_STDOUT=/tmp/aws_stdout_wait DB_STDERR=/tmp/aws_stderr_wait AWS rds wait db-instance-available \
        --db-instance-identifier "$DB_HOST"

    DB_HOST_CREATED="1"
    if [[ -n "$DELETE_DB_AFTER_SLEEP" ]]; then
        nohup sleep "${DELETE_DB_AFTER_SLEEP}" && \
            AWS rds delete-db-instance \
            --db-instance-identifier "$DB_HOST" \
            --skip-final-snapshot \
            >> ~/nohup.out 2>&1 &
        echo -e "\nDeleting ${DB_HOST} after ${DELETE_DB_AFTER_SLEEP}.  To cancel kill -9 $! \n"
    fi

    AWS rds describe-db-instances \
        --db-instance-identifier "$DB_HOST"
fi

# MariaDB RDS has no OptionGroupMemberships; get parameter group name only
read -rd "\n" DB_HOST_FQDN DB_PORT DB_VPC_ID DBParameterGroupName <<< "$(jq -r '.DBInstances.[] | .Endpoint.Address, .Endpoint.Port, .DBSubnetGroup.VpcId, (.DBParameterGroups.[] | .DBParameterGroupName)' /tmp/aws_stdout.$$)"
read -rd "\n" DBInstanceArn <<< "$(jq -r '.. | .DBInstanceArn? // empty' /tmp/aws_stdout.$$)"
read -rd "\n" VpcSecurityGroupId <<< "$(jq -r '.. | .VpcSecurityGroupId? // empty' /tmp/aws_stdout.$$)"
export DB_HOST_FQDN DB_PORT
export DBInstanceArn

# #############################################################################

echo -e "\nCreating permissive firewall rules if not exists"
echo -e   "------------------------------------------------\n"

firewall_rule() {
    # Default when unset (avoids "unbound variable" under set -u)
    local _raw="${DB_FIREWALL_CIDRS:-0.0.0.0/0}"
    # Normalize to one CIDR per array element (handles space-separated string or array)
    local -a cidrs
    if [[ "$_raw" == *" "* ]]; then
        read -ra cidrs <<< "$_raw"
    else
        cidrs=( "$_raw" )
    fi
    # IpRanges must be list of dicts: [{CidrIp=...},{CidrIp=...}], not bare CIDR strings
    printf -v DB_FIREWALL_CIDRS_CSV "{CidrIp=%s}," "${cidrs[@]}"
    DB_FIREWALL_CIDRS_CSV="${DB_FIREWALL_CIDRS_CSV%,}"

    # https://docs.aws.amazon.com/cli/latest/reference/ec2/authorize-security-group-ingress.html
    DB_EXIT_ON_ERROR="PRINT_EXIT" AWS ec2 authorize-security-group-ingress \
        --group-name "$DB_SG_NAME" \
        --ip-permissions "IpProtocol=tcp,FromPort=$DB_PORT,ToPort=$DB_PORT,IpRanges=[$DB_FIREWALL_CIDRS_CSV]"
}

if ! AWS ec2 describe-security-groups \
    --group-name "$DB_SG_NAME" \
    ; then

    DB_EXIT_ON_ERROR="PRINT_EXIT" AWS ec2 create-security-group \
        --tag-specifications "ResourceType=security-group,Tags=[{Key=Owner,Value=${DBX_USERNAME}},${REMOVE_AFTER:+{Key=RemoveAfter,Value=${REMOVE_AFTER}}}]" \
        --description "security group for MariaDB RDS" \
        --group-name "$DB_SG_NAME" \
        --vpc-id "$DB_VPC_ID"

    AWS ec2 describe-security-groups \
        --group-name "$DB_SG_NAME"
fi

read -rd "\n" DB_SG_ID <<< "$(jq -r '.SecurityGroups.[] | .GroupId' /tmp/aws_stdout.$$)"

DB_SG_ID_CHANGED=""
if [[ "$DB_SG_ID" != "$VpcSecurityGroupId" ]]; then
    (( DB_SG_ID_CHANGED += 1 ))
fi

# #############################################################################
# set replication (binlog for CDC)

echo -e "\nCreate parameters binlog_format=ROW, binlog_row_image=FULL for Lakeflow Connect"
echo -e   "---------------------------------------------------------------------------------\n"

# Parameter group name is e.g. default.mariadb10.11 -> family mariadb10.11
db_parameter_group_family="${DBParameterGroupName#*.}"
DB_PARM_GRP_NAME="$(echo "${db_parameter_group_family}" | tr -dc 'a-zA-Z0-9-')"

if ! AWS rds describe-db-parameter-groups \
    --db-parameter-group-name "$DB_PARM_GRP_NAME" \
    ; then

    DB_EXIT_ON_ERROR="PRINT_EXIT" AWS rds create-db-parameter-group \
        --db-parameter-group-name "$DB_PARM_GRP_NAME" \
        --db-parameter-group-family "$db_parameter_group_family" \
        --description "MariaDB parameter group for Lakeflow Connect"

    if [[ -n "$DELETE_DB_AFTER_SLEEP" ]]; then
        nohup sleep "${DELETE_DB_AFTER_SLEEP}" && \
            AWS rds delete-db-parameter-group \
            --db-parameter-group-name "$DB_PARM_GRP_NAME" \
            >> ~/nohup.out 2>&1 &
        echo -e "\nDeleting ${DB_PARM_GRP_NAME} after ${DELETE_DB_AFTER_SLEEP}.  To cancel kill -9 $! \n"
    fi
fi

aws_rds_build_db_param_group() {
    local name=$1
    local value=$2
    local method=${3:-"pending-reboot"}
    if [[ "${value,,}" != "$(jq --arg name "$name" -r '.Parameters.[] | select(.ParameterName == $name) | .ParameterValue | ascii_downcase' /tmp/aws_parm_list.$$ 2>/dev/null)" ]]; then
        DB_PARAMS_CHANGED="${DB_PARAMS_CHANGED:+${DB_PARAMS_CHANGED},}{\"ParameterName\":\"$name\", \"ParameterValue\":\"$value\", \"ApplyMethod\": \"$method\"}"
    fi
}

DB_PARAMS_CHANGED=""
DB_EXIT_ON_ERROR="PRINT_EXIT" DB_STDOUT=/tmp/aws_parm_list.$$ AWS rds describe-db-parameters --db-parameter-group-name "$DB_PARM_GRP_NAME"

aws_rds_build_db_param_group "binlog_format" "ROW"
aws_rds_build_db_param_group "binlog_row_image" "FULL"

if [[ -n ${DB_PARAMS_CHANGED} ]]; then
    DB_EXIT_ON_ERROR="PRINT_EXIT" AWS rds modify-db-parameter-group --db-parameter-group-name "$DB_PARM_GRP_NAME" --parameters "[$DB_PARAMS_CHANGED]"
fi

if [[ "$DBParameterGroupName" != "$DB_PARM_GRP_NAME" ]]; then
    (( DB_PARAMS_CHANGED += 1 ))
fi

# #############################################################################
# apply / reboot wait

echo -e "\napply and reboot and wait online if required"
echo -e   "--------------------------------------------\n"

if [[ -n $DB_PARAMS_CHANGED || -n $DB_SG_ID_CHANGED ]]; then
    DB_EXIT_ON_ERROR="PRINT_EXIT" AWS rds modify-db-instance \
        --db-instance-identifier "$DB_HOST" \
        ${DB_SG_ID_CHANGED:+--vpc-security-group-ids "$DB_SG_ID"} \
        ${DB_PARAMS_CHANGED:+--db-parameter-group-name "$DB_PARM_GRP_NAME"}

    AWS rds describe-db-instances \
        --db-instance-identifier "$DB_HOST"

    MODIFY_DB_INSTANCE_WAIT=0
    while [[ -n $(jq -r '.. | (.DBParameterGroups? // empty | .[] | select(.ParameterApplyStatus == "applying")), (.VpcSecurityGroups? // empty | .[] | select(.Status == "adding" or .Status == "removing"))' /tmp/aws_stdout.$$) ]]; do
        echo "$MODIFY_DB_INSTANCE_WAIT: waiting for firewall and / or parm to apply"
        sleep 30
        AWS rds describe-db-instances \
            --db-instance-identifier "$DB_HOST"
        (( MODIFY_DB_INSTANCE_WAIT += 1 ))
    done

    if [[ $MODIFY_DB_INSTANCE_WAIT != "0" ]]; then
        DB_EXIT_ON_ERROR="PRINT_EXIT" AWS rds reboot-db-instance \
            --db-instance-identifier "$DB_HOST"

        DB_EXIT_ON_ERROR="PRINT_EXIT" DB_STDOUT=/tmp/aws_stdout_wait DB_STDERR=/tmp/aws_stderr_wait AWS rds wait db-instance-available \
            --db-instance-identifier "$DB_HOST"
    fi
fi

# #############################################################################
# reinit firewall if empty

DB_EXIT_ON_ERROR="PRINT_EXIT" AWS ec2 describe-security-groups \
    --group-name "$DB_SG_NAME"

DB_SG_RULE_LEN=$(jq -r '.. | objects | select(.FromPort=='$DB_PORT' and .ToPort=='$DB_PORT') | .IpRanges | length' /tmp/aws_stdout.$$)

if (( DB_SG_RULE_LEN == 0 )); then
    firewall_rule
fi

# #############################################################################
# create catalog if not exists

echo -e "\nCreate catalog if not exists"
echo -e   "----------------------------\n"

DB_EXIT_ON_ERROR="PRINT_EXIT" DB_STDOUT=/tmp/mysql_stdout.$$ DB_STDERR=/tmp/mysql_stderr.$$ DB_USERNAME="${DBA_USERNAME}" DB_PASSWORD="${DBA_PASSWORD}" DB_CATALOG="mysql" MYSQLCLI -e "SHOW DATABASES;" </dev/null

if [[ -n "$DB_HOST" ]] && [[ -z "${DB_CATALOG}" || "$DB_CATALOG" == "${CATALOG_BASENAME}" ]]; then
    # use first non-system database if any
    while read -r db; do
        case "$db" in information_schema|mysql|performance_schema|sys) continue ;; esac
        DB_CATALOG="$db"
        break
    done < /tmp/mysql_stdout.$$
fi

if [[ -z "${DB_CATALOG}" ]]; then
    DB_CATALOG="${CATALOG_BASENAME}"
fi

if ! grep -qFx "$DB_CATALOG" /tmp/mysql_stdout.$$ 2>/dev/null; then
    db_to_create="${DB_CATALOG}"
    DB_EXIT_ON_ERROR="PRINT_EXIT" DB_USERNAME="${DBA_USERNAME}" DB_PASSWORD="${DBA_PASSWORD}" DB_CATALOG="mysql" MYSQLCLI -e "CREATE DATABASE IF NOT EXISTS \`${db_to_create}\`;" 
fi

# #############################################################################
# save secrets and next step

if should_save_secrets; then
    put_secrets
    put_secrets "${DB_HOST}" "json"
fi

echo -e "\nRun the following step (if using MySQL/MariaDB configure):"
echo -e "----------------------------------------------------------------"
echo -e "source  <(curl -s -L https://raw.githubusercontent.com/rsleedbx/lakeflow_connect/refs/heads/main/mysql/02_mysql_configure.sh)"
echo ""
