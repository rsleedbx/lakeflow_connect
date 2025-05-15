#!/usr/bin/env bash

# error out when undeclared variable is used
set -u 

# must be sourced for exports to continue to the next script
if [ "$0" == "$BASH_SOURCE" ]; then
  echo "Script is being executed directly. Please run as source $0"
  exit 1
fi

export PG_VERSION=${PG_VERSION:-""}     # take the default
export CLOUD_DB_TYPE=wp
export CLOUD_DB_SUFFIX=wp
export CONNECTION_TYPE=POSTGRESQL
export SOURCE_TYPE=$CONNECTION_TYPE

DB_SG_NAME="${WHOAMI}-5432-sg"
DB_SG_ID=""

# #############################################################################
# set sqlcli to psql

SQLCLI() {
    PSQL "${@}"
}
export -f SQLCLI

# #############################################################################
# init cloud

AWS_INIT

# #############################################################################
# use default of from the secrets

# secrets was empty or invalid.
if [[ -z "${DBA_USERNAME}" || -z "$DB_HOST" || "$DB_HOST" == "${DB_BASENAME}" || "$DB_HOST" != *"-${CLOUD_DB_SUFFIX}" ]]; then 
    if [[ "${CDC_CT_MODE}" =~ ^(CT)$ ]]; then 
        DB_HOST="${DB_BASENAME}-ct-${CLOUD_DB_SUFFIX}"; 
    else
        DB_HOST="${DB_BASENAME}-${CLOUD_DB_SUFFIX}"; 
    fi
fi 

if [[ -z "${DB_CATALOG}" ]]; then
    DB_CATALOG="$CATALOG_BASENAME"
fi

# #############################################################################
# create postgres server

echo -e "\nCreate postgres server if not exists (about 5 mins to create)"
echo -e   "-------------------------------------------------------------\n"

export DB_HOST_CREATED=""

if ! AWS rds describe-db-instances \
    --db-instance-identifier $DB_HOST \
    ; then

    # https://docs.aws.amazon.com/cli/latest/reference/rds/create-db-instance.html
    # db.m5.large
    # db.t3.large not supported
    DB_EXIT_ON_ERROR="PRINT_EXIT" AWS rds create-db-instance \
        --tags "Key=Owner,Value=${DBX_USERNAME}" "${REMOVE_AFTER:+Key=RemoveAfter,Value=${REMOVE_AFTER}}" \
        --db-instance-identifier "$DB_HOST" \
        --db-name "$DB_CATALOG" \
        --db-instance-class db.m5.large \
        --engine postgres ${PG_VERSION:+--engine-version "$PG_VERSION"} \
        --no-auto-minor-version-upgrade \
        --license-model postgresql-license \
        --master-username "$DBA_USERNAME" \
        --master-user-password "$DBA_PASSWORD" \
        --allocated-storage 32 \
        --backup-retention-period 0 \
        ${DB_SG_ID:+--vpc-security-group-ids "$DB_SG_ID"}

    # https://docs.aws.amazon.com/cli/latest/reference/rds/wait/db-instance-available.html
    DB_EXIT_ON_ERROR="PRINT_EXIT" DB_STDOUT=/tmp/aws_stdout_wait DB_STDERR=/tmp/aws_stderr_wait AWS rds wait db-instance-available \
        --db-instance-identifier "$DB_HOST" 

    DB_HOST_CREATED="1"
    if [[ -n "$DELETE_DB_AFTER_SLEEP" ]]; then
        # </dev/null solves Fatal Python error: init_sys_streams: can't initialize sys standard streams
        nohup sleep "${DELETE_DB_AFTER_SLEEP}" && \
            AWS rds delete-db-instance \
            --db-instance-identifier "$DB_HOST" \
            --skip-final-snapshot \
            >> ~/nohup.out 2>&1 &
        echo -e "\nDeleting ${DB_HOST} after ${DELETE_DB_AFTER_SLEEP}.  To cancel kill -9 $! \n" 
    fi

    AWS rds describe-db-instances \
        --db-instance-identifier $DB_HOST 
fi

read -rd "\n" DB_HOST_FQDN DB_PORT DB_VPC_ID OptionGroupName DBParameterGroupName <<< "$(jq -r '.DBInstances.[] | .Endpoint.Address, .Endpoint.Port, .DBSubnetGroup.VpcId, (.OptionGroupMemberships.[] | .OptionGroupName), (.DBParameterGroups.[] | .DBParameterGroupName)' /tmp/aws_stdout.$$)"
read -rd "\n" DBInstanceArn <<< "$(jq -r '.. | .DBInstanceArn? // empty' /tmp/aws_stdout.$$)"
read -rd "\n" VpcSecurityGroupId <<< "$(jq -r '.. | .VpcSecurityGroupId? // empty' /tmp/aws_stdout.$$)"

# #############################################################################

echo -e "\nCreating permissive firewall rules if not exists"
echo -e   "------------------------------------------------\n"

firewall_rule() {
    printf -v DB_FIREWALL_CIDRS_CSV "{CidrIp='%s'}," "${DB_FIREWALL_CIDRS[@]}"
    DB_FIREWALL_CIDRS_CSV="${DB_FIREWALL_CIDRS_CSV%,}"  # remove trailing ,

    # https://docs.aws.amazon.com/cli/latest/reference/ec2/authorize-security-group-ingress.html
    DB_EXIT_ON_ERROR="PRINT_EXIT" AWS ec2 authorize-security-group-ingress \
        --group-name "$DB_SG_NAME" \
        --ip-permissions "IpProtocol=tcp,IpRanges=[$DB_FIREWALL_CIDRS_CSV],FromPort=$DB_PORT,ToPort=$DB_PORT"     
}

if ! AWS ec2 describe-security-groups \
    --group-name "$DB_SG_NAME" \
    ; then

    DB_EXIT_ON_ERROR="PRINT_EXIT" AWS ec2 create-security-group \
        --tag-specifications "ResourceType=security-group,Tags=[{Key=Owner,Value=${DBX_USERNAME}},${REMOVE_AFTER:+{Key=RemoveAfter,Value=${REMOVE_AFTER}}}]" \
        --description "security group for postgres" \
        --group-name "$DB_SG_NAME" \
        --vpc-id "$DB_VPC_ID" 

    firewall_rule

    AWS ec2 describe-security-groups \
        --group-name "$DB_SG_NAME" 

    if [[ -n "$DELETE_DB_AFTER_SLEEP" ]]; then
        nohup sleep "${DELETE_DB_AFTER_SLEEP}" && \
            AWS ec2 delete-security-group \
            --group-name "$DB_SG_NAME" \
            >> ~/nohup.out 2>&1 &
        echo -e "\nDeleting ${DB_SG_NAME} after ${DELETE_DB_AFTER_SLEEP}.  To cancel kill -9 $! \n" 
    fi
fi

read -rd "\n" DB_SG_ID <<< "$(jq -r '.SecurityGroups.[] | .GroupId' /tmp/aws_stdout.$$)"

DB_SG_ID_CHANGED=""
if [[ "$DB_SG_ID" != "$VpcSecurityGroupId" ]]; then 
    (( DB_SG_ID_CHANGED += 1 ))
fi

# #############################################################################
# set replication

echo -e "\nCreate parameters wal_level=logical and require_secure_transport=off" 
echo -e   "--------------------------------------------------------------------\n"

db_parameter_group_family="${OptionGroupName#*:}"               # Removes from the beginning to the first ':'
db_parameter_group_family="${db_parameter_group_family//-/}"    # Removes all '-'
DB_PARM_GRP_NAME="${WHOAMI}-lakeflow-${db_parameter_group_family}"

# create param group name if not exists
if ! AWS rds describe-db-parameter-groups \
    --db-parameter-group-name "$DB_PARM_GRP_NAME" \
    ; then

    AWS rds create-db-parameter-group \
        --db-parameter-group-name "$DB_PARM_GRP_NAME" \
        --db-parameter-group-family "$db_parameter_group_family" \
        --description "db_parameter_group_family lakeflow"

    if [[ -n "$DELETE_DB_AFTER_SLEEP" ]]; then
        nohup sleep "${DELETE_DB_AFTER_SLEEP}" && \
            AWS rds delete-db-parameter-group \
            --db-parameter-group-name "$DB_PARM_GRP_NAME" \
            >> ~/nohup.out 2>&1 &
        echo -e "\nDeleting ${DB_SG_NAME} after ${DELETE_DB_AFTER_SLEEP}.  To cancel kill -9 $! \n" 
    fi

fi

DB_PARAMS_CHANGED=""
AWS rds describe-db-parameters \
    --db-parameter-group-name "$DB_PARM_GRP_NAME" \
    --query "Parameters[?ParameterName=='rds.logical_replication' || ParameterName=='rds.force_ssl']"

if [[ "1" != "$(jq -r '.[] | select(.ParameterName=="rds.logical_replication") | .ParameterValue' /tmp/aws_stdout.$$)" ]]; then
    DB_EXIT_ON_ERROR="PRINT_EXIT" AWS rds modify-db-parameter-group \
    --db-parameter-group-name "$DB_PARM_GRP_NAME" \
    --parameters '[
    {"ParameterName":"max_replication_slots",   "ParameterValue":"10",  "ApplyMethod": "pending-reboot"},
    {"ParameterName":"max_wal_senders",         "ParameterValue":"15",  "ApplyMethod": "pending-reboot"}, 
    {"ParameterName":"max_worker_processes",    "ParameterValue":"10",  "ApplyMethod": "pending-reboot"}, 
    {"ParameterName":"rds.logical_replication", "ParameterValue":"1",   "ApplyMethod": "pending-reboot"}
]'
    (( DB_PARAMS_CHANGED += 1 ))
fi

if [[ "0" != "$(jq -r '.[] | select(.ParameterName=="rds.force_ssl") | .ParameterValue' /tmp/aws_stdout.$$)" ]]; then
DB_EXIT_ON_ERROR="PRINT_EXIT" AWS rds modify-db-parameter-group \
    --db-parameter-group-name "$DB_PARM_GRP_NAME" \
    --parameters '[
    {"ParameterName":"rds.force_ssl",           "ParameterValue":"off", "ApplyMethod": "pending-reboot"}
]'
    (( DB_PARAMS_CHANGED += 1 ))
fi

# #############################################################################
# apply / reboot wait

echo -e "\napply and reboot and wait online if required" 
echo -e   "--------------------------------------------\n"

#AWS rds describe-pending-maintenance-actions \
#    --resource-identifier "$DBInstanceArn"

# modify instance
if [[ -n $DB_PARAMS_CHANGED || -n $DB_SG_ID_CHANGED ]]; then
    DB_EXIT_ON_ERROR="PRINT_EXIT" AWS rds modify-db-instance \
        --db-instance-identifier "$DB_HOST" \
        ${DB_SG_ID_CHANGED:+--vpc-security-group-ids "$DB_SG_ID"} \
        ${DB_PARAMS_CHANGED:+--db-parameter-group-name "$DB_PARM_GRP_NAME"} 

    # wait for firewall to apply
    AWS rds describe-db-instances \
        --db-instance-identifier $DB_HOST

    # wait for the below to finish
    # "VpcSecurityGroups": [
    #   "Status": "removing" | "adding"
    # "DBParameterGroups": [
    #   "ParameterApplyStatus": "applying

    MODIFY_DB_INSTANCE_WAIT=0
    while [[ -n $(jq -r '.. | (.DBParameterGroups? // empty | .[] | select(.ParameterApplyStatus == "applying")), (.VpcSecurityGroups? // empty | .[] | select(.Status == "adding" or .Status == "removing"))' /tmp/aws_stdout.$$) ]]; do
        echo "$MODIFY_DB_INSTANCE_WAIT: waiting for firewall and / or parm to apply"
        sleep 30
        AWS rds describe-db-instances \
            --db-instance-identifier $DB_HOST
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
# create catalog if not exists 

echo -e "\nCreate catalog if not exists" 
echo -e   "----------------------------\n"

# get avail catalog if not specified
DB_CATALOG="postgres" SQLCLI_DBA -c "select datname from pg_database where datname not in ('rdsadmin', 'postgres') and datname not like 'template%';" </dev/null

# use existing catalog
if [[ -n "$DB_HOST" ]] && [[ -z "${DB_CATALOG}" || "$DB_CATALOG" == "${CATALOG_BASENAME}" ]]; then 
    DB_CATALOG=$(cat /tmp/psql_stdout.$$)
fi 

if [[ -z "${DB_CATALOG}" ]]; then 
    DB_CATALOG="${CATALOG_BASENAME}"
fi

# create if catalog does not exist
if ! grep -q "^$DB_CATALOG" /tmp/psql_stdout.$$; then
    DB_EXIT_ON_ERROR="PRINT_EXIT" DB_CATALOG="postgres" SQLCLI_DBA -c "create database ${DB_CATALOG};"
fi
