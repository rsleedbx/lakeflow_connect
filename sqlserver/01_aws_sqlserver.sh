#!/usr/bin/env bash

# error out when undeclared variable is used
set -u 

# must be sourced for exports to continue to the next script
if [ "$0" == "$BASH_SOURCE" ]; then
  echo "Script is being executed directly. Please run as source $0"
  exit 1
fi

export CLOUD_DB_TYPE=ws
export CLOUD_DB_SUFFIX=ws
export CONNECTION_TYPE=SQLSERVER
export SOURCE_TYPE=$CONNECTION_TYPE

# #############################################################################
# export functions

SQLCLI() {
    SQLCMD "${@}"
}
export -f SQLCLI

# #############################################################################
# export functions

AWS_INIT

# secrets was empty or invalid.
if [[ -z "${DBA_USERNAME}" || -z "${DB_CATALOG}" || -z "$DB_HOST" || "$DB_HOST" != *"-${CLOUD_DB_SUFFIX}" ]]; then 
    if [[ "${CDC_CT_MODE}" =~ ^(CT)$ ]]; then 
        DB_HOST="${DB_BASENAME}-ct-${CLOUD_DB_SUFFIX}"; 
    else
        DB_HOST="${DB_BASENAME}-${CLOUD_DB_SUFFIX}"; 
    fi
    DB_CATALOG="$CATALOG_BASENAME"
fi 

# #############################################################################
# create sql server

echo -e "\nCreate sql server if not exists (about 5 mins to create)"
echo -e   "-------------------------------------------------------\n"

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
        --db-instance-class db.m5.large \
        --engine sqlserver-se \
        --master-username "$DBA_USERNAME" \
        --master-user-password "$DBA_PASSWORD" \
        --license-model license-included \
        --allocated-storage 32 \
        --backup-retention-period 0

    # https://docs.aws.amazon.com/cli/latest/reference/rds/wait/db-instance-available.html
    DB_EXIT_ON_ERROR="PRINT_EXIT" DB_STDOUT=/tmp/aws_stdout_wait DB_STDERR=/tmp/aws_stderr_wait AWS rds wait db-instance-available \
        --db-instance-identifier $DB_HOST 

    DB_HOST_CREATED="1"
    if [[ -n "$DELETE_DB_AFTER_SLEEP" ]]; then
        # </dev/null solves Fatal Python error: init_sys_streams: can't initialize sys standard streams
        nohup sleep "${DELETE_DB_AFTER_SLEEP}" && \
            AWS rds delete-db-instance \
            --db-instance-identifier "$DB_HOST" \
            >> ~/nohup.out 2>&1 &
        echo -e "\nDeleting ${DB_HOST} after ${DELETE_DB_AFTER_SLEEP}.  To cancel kill -9 $! \n" 
    fi

    AWS rds describe-db-instances \
        --db-instance-identifier $DB_HOST 
fi

read -rd "\n" DB_HOST_FQDN DB_PORT DB_VPC_ID <<< "$(jq -r '.DBInstances.[] | .Endpoint.Address, .Endpoint.Port, .DBSubnetGroup.VpcId' /tmp/aws_stdout.$$)"

# #############################################################################

echo -e "\nCreating permissive firewall rules if not exists"
echo -e   "------------------------------------------------\n"

DB_SG_NAME="${WHOAMI}-1433-sg"

if ! AWS ec2 describe-security-groups \
    --group-name "$DB_SG_NAME" \
    ; then

    DB_EXIT_ON_ERROR="PRINT_EXIT" AWS ec2 create-security-group \
        --tags "Key=Owner,Value=${DBX_USERNAME}" "${REMOVE_AFTER:+Key=RemoveAfter,Value=${REMOVE_AFTER}}" \
        --description "security group for $DB_HOST" \
        --group-name "$DB_SG_NAME" \
        --vpc-id "$DB_VPC_ID" 

    printf -v DB_FIREWALL_CIDRS_CSV "{CidrIp='%s'}," "${DB_FIREWALL_CIDRS[@]}"
    DB_FIREWALL_CIDRS_CSV="${DB_FIREWALL_CIDRS_CSV%,}"  # remove trailing ,

    # https://docs.aws.amazon.com/cli/latest/reference/ec2/authorize-security-group-ingress.html
    DB_EXIT_ON_ERROR="PRINT_EXIT" AWS ec2 authorize-security-group-ingress \
        --group-name "$DB_SG_NAME" \
        --ip-permissions "IpProtocol=tcp,IpRanges=[$DB_FIREWALL_CIDRS_CSV],FromPort=$DB_PORT,ToPort=$DB_PORT" 

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

AWS rds modify-db-instance \
    --db-instance-identifier "$DB_HOST" \
    --vpc-security-group-ids "$DB_SG_ID" 

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

kill -INT $$
