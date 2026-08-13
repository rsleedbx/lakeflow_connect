#!/usr/bin/env bash

# error out when undeclared variable is used
set -u 

# must be sourced for exports to continue to the next script
if [ "$0" == "$BASH_SOURCE" ]; then
  echo "Script is being executed directly. Please run as source $0"
  return 1
fi

# mysql does not have catalog concept

if [[ "$DML_INTERVAL_SEC" -eq 0 ]] && [[ "${DB_SCHEMA}" != *"_${DML_INTERVAL_SEC}tps"* ]]; then
    DB_SCHEMA="${DB_SCHEMA}_${DML_INTERVAL_SEC}tps"
    echo "Changing schema to $DB_SCHEMA"
fi

if [[ "$INITIAL_SNAPSHOT_ROWS" -eq 0 ]] && [[ "${DB_SCHEMA}" != *"_${INITIAL_SNAPSHOT_ROWS}row"* ]]; then
    DB_SCHEMA="${DB_SCHEMA}_${INITIAL_SNAPSHOT_ROWS}row"
    echo "Changing schema to $DB_SCHEMA"
fi

# #############################################################################
# dml generator for mysql

# make sure to quote echo "$sql_dml_generator" otherwise the newline will be removed 
if ! declare -p sql_dml_generator &> /dev/null; then
echo "using default sql_dml_generator.  echo \"\$sql_dml_generator\" to view" 
    sql_dml_generator="call $DB_SCHEMA.endless_dml_loop(NULL, NULL);"
fi

# #############################################################################

# connect to mysql system catalog as DBA
DB_EXIT_ON_ERROR="PRINT_EXIT" DB_USERNAME="$DBA_USERNAME" DB_PASSWORD="$DBA_PASSWORD" DB_CATALOG="mysql" TEST_DB_CONNECT

# #############################################################################
# create user login.  user by default = role + login

echo -e "Creating user"

if [[ -z "$USER_USERNAME" || "$USER_USERNAME" == "$USER_BASENAME" ]]; then
    DB_CATALOG="mysql" SQLCLI_DBA -e "SELECT user FROM mysql.user WHERE user not in ('azure_superuser','azure_superuser','mysql.infoschema','mysql.session','mysql.sys','mariadb.infoschema','mariadb.session','mariadb.sys', 'rdsadmin');" </dev/null
    if grep -q -v -m 1 "^${DBA_USERNAME}$" /tmp/mysql_stdout.$$; then 
        USER_USERNAME=$(grep -v -m 1 "^${DBA_USERNAME}$" /tmp/mysql_stdout.$$)
        echo "Retrieving USER_USERNAME=$USER_USERNAME"
    else
        USER_USERNAME="$USER_BASENAME"
        echo "Setting USER_USERNAME=$USER_BASENAME"
    fi
fi

DB_EXIT_ON_ERROR="PRINT_EXIT" DB_CATALOG="mysql" SQLCLI_DBA <<EOF
create user if not exists ${USER_USERNAME}@'%' IDENTIFIED WITH caching_sha2_password BY '${USER_PASSWORD}';
-- set / reset password + auth plugin (MySQL 8 / Azure Flexible Server)
alter user ${USER_USERNAME}@'%' IDENTIFIED WITH caching_sha2_password BY '${USER_PASSWORD}';
-- grant DML access for demo loop (CDC replication grants come from lakeflow_setup_cdc_user)
grant alter,create,drop, select,insert,delete, update on *.* to ${USER_USERNAME};
FLUSH PRIVILEGES;
EOF

# connect to mysql as a user
DB_EXIT_ON_ERROR="PRINT_EXIT" DB_USERNAME="$USER_USERNAME" DB_PASSWORD="$USER_PASSWORD" DB_CATALOG="mysql" TEST_DB_CONNECT

# #############################################################################

# remove left over slot names
db_replication_cleanup() {
    :
}
export -f db_replication_cleanup

# #############################################################################

# enable schema evolution


# #############################################################################

# create schema

echo -e "Creating schema\n"

DB_CATALOG="mysql" SQLCLI -e "create schema if not exists ${DB_SCHEMA}" </dev/null
# /tmp/mysql_stdout.$$ will be 0 if schema was created.  drop the schema when done

if [[ ! -s /tmp/mysql_stderr.$$ ]] && [[ -n "${DELETE_DB_AFTER_SLEEP}" ]]; then
    nohup sleep "${DELETE_DB_AFTER_SLEEP}" && DB_STDOUT=~/nohup.out DB_STDERR=~/nohup.out DB_CATALOG="mysql" SQLCLI >>~/nohup.out 2>&1 << EOF &
    drop table if exists ${DB_SCHEMA}.intpk; 
    drop table if exists ${DB_SCHEMA}.dtix; 
    drop schema if exists ${DB_SCHEMA};
EOF
    echo -e "\nDeleting ${DB_SCHEMA} schema after ${DELETE_DB_AFTER_SLEEP}.  To cancel kill -9 $!\n" 
fi

# #############################################################################
# create user in the catalog

echo -e "Creating DML store proc\n"

DB_EXIT_ON_ERROR="PRINT_EXIT" DB_CATALOG="$DB_SCHEMA" SQLCLI_DBA -e 'DROP PROCEDURE IF EXISTS endless_dml_loop' </dev/null

DB_EXIT_ON_ERROR="PRINT_EXIT" DB_CATALOG="$DB_SCHEMA" SQLCLI_DBA <<'EOF'
DELIMITER $$

CREATE PROCEDURE endless_dml_loop(
    IN dml_interval_sec INT,
    IN max_iterations INT
)
BEGIN
    DECLARE counter INT DEFAULT 0;
    DECLARE sleep_interval INT DEFAULT COALESCE(dml_interval_sec, 60);
    DECLARE stop_after INT DEFAULT COALESCE(max_iterations, 30);
    
    WHILE counter < stop_after DO
        -- intpk
        INSERT INTO intpk (dt) VALUES (CURRENT_TIMESTAMP()), (CURRENT_TIMESTAMP()), (CURRENT_TIMESTAMP());
        COMMIT;
        
        DELETE FROM intpk WHERE pk = (SELECT min_pk FROM (SELECT MIN(pk) AS min_pk FROM intpk) AS temp);
        COMMIT;
        
        UPDATE intpk SET dt = CURRENT_TIMESTAMP() WHERE pk = (SELECT min_pk FROM (SELECT MIN(pk) AS min_pk FROM intpk) AS temp);
        COMMIT;
        
        -- dtix
        INSERT INTO dtix (pk,dt) VALUES (1,CURRENT_TIMESTAMP()), (2,CURRENT_TIMESTAMP()), (3,CURRENT_TIMESTAMP());
        COMMIT;

        SELECT CONCAT('Counter ', counter, ' of ', stop_after, ' (sleeping ', sleep_interval, 's)') AS notice;
        SET counter = counter + 1;
        DO SLEEP(sleep_interval);
    END WHILE;
    
    SELECT CONCAT('Completed ', counter, ' iterations') AS final_notice;
END;
EOF

DB_EXIT_ON_ERROR="PRINT_EXIT" DB_CATALOG="$DB_SCHEMA" SQLCLI_DBA <<EOF
GRANT EXECUTE ON PROCEDURE endless_dml_loop TO ${USER_USERNAME};
EOF

# #############################################################################

# create tables

echo -e "Creating tables\n"

DB_EXIT_ON_ERROR="PRINT_EXIT" DB_CATALOG="${DB_SCHEMA}" SQLCLI <<EOF
    create table if not exists ${DB_SCHEMA}.intpk (
        pk serial primary key, 
        dt timestamp DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP, 
        ops varchar(255) default 'insert');
    create table if not exists ${DB_SCHEMA}.dtix (
        pk bigint, 
        dt timestamp DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP, 
        ops varchar(255) default 'insert');
EOF

if [[ "$INITIAL_SNAPSHOT_ROWS" -gt 0 ]]; then
DB_CATALOG="${DB_SCHEMA}" SQLCLI <<EOF
    insert into ${DB_SCHEMA}.intpk (dt) values (CURRENT_TIMESTAMP),(CURRENT_TIMESTAMP), (CURRENT_TIMESTAMP);
    insert into ${DB_SCHEMA}.dtix (pk,dt) values (1,CURRENT_TIMESTAMP),(2,CURRENT_TIMESTAMP),(3,CURRENT_TIMESTAMP);
    select concat('${DB_SCHEMA}.intpk,', max(pk)) from ${DB_SCHEMA}.intpk;
    select concat('${DB_SCHEMA}.dtix,', max(dt)) from ${DB_SCHEMA}.dtix limit 1;    
EOF

# .\+ = one or more so that nulls are not accepted
if grep "^${DB_SCHEMA}.intpk,.\+$" /tmp/mysql_stdout.$$; then echo "table intpk ok $DB_SCHEMA schema $DB_HOST_FQDN,${DB_PORT} $DBA_USERNAME"; 
else cat /tmp/mysql_stdout.$$ /tmp/mysql_stderr.$$
    return 1
fi

# .\+ = one or more so that nulls are not accepted
if grep "^${DB_SCHEMA}.dtix,.\+$" /tmp/mysql_stdout.$$ ; then echo "table dtix ok $DB_SCHEMA schema $DB_HOST_FQDN,${DB_PORT} $DBA_USERNAME"; 
else cat /tmp/mysql_stdout.$$ /tmp/mysql_stderr.$$
    return 1
fi
fi

# #############################################################################
# Install Lakeflow MySQL utility objects + CDC grants (after tables exist)
# Docs: https://docs.databricks.com/aws/en/ingestion/lakeflow-connect/mysql-utility-script
# Skip lakeflow_cdc_setup on Azure — binlog is set via server parameters in 01.

echo -e "\nInstalling MySQL utility objects + CDC grants (latest registered)"
echo -e   "----------------------------------------------------------------\n"

DB_USERNAME="${DBA_USERNAME}" DB_PASSWORD="${DBA_PASSWORD}" DB_CATALOG="${DB_SCHEMA}" \
  python3 "${_LFC_REPO_ROOT}/utils/mysql-utility-script.py" \
    --apply \
    --user "${USER_USERNAME}" \
    --tables "\`${DB_SCHEMA}\`.*" || return 1

# Verify utility procedures installed in DB_SCHEMA
DB_EXIT_ON_ERROR="PRINT_EXIT" DB_CATALOG="${DB_SCHEMA}" SQLCLI_DBA -e \
  "SELECT ROUTINE_NAME FROM information_schema.ROUTINES WHERE ROUTINE_SCHEMA='${DB_SCHEMA}' AND ROUTINE_TYPE='PROCEDURE' AND ROUTINE_NAME IN ('lakeflow_cdc_setup','lakeflow_setup_cdc_user') ORDER BY ROUTINE_NAME;" \
  </dev/null
if ! grep -q "lakeflow_cdc_setup" /tmp/mysql_stdout.$$ || ! grep -q "lakeflow_setup_cdc_user" /tmp/mysql_stdout.$$; then
    echo "ERROR: lakeflow utility procedures not found in schema ${DB_SCHEMA}" >&2
    cat /tmp/mysql_stdout.$$ /tmp/mysql_stderr.$$
    return 1
fi
echo "utility procedures ok: lakeflow_cdc_setup, lakeflow_setup_cdc_user"

# Verify CDC user grants (replication + select)
DB_EXIT_ON_ERROR="PRINT_EXIT" DB_CATALOG="mysql" SQLCLI_DBA -e \
  "SHOW GRANTS FOR '${USER_USERNAME}'@'%';" </dev/null
if ! grep -qi "REPLICATION" /tmp/mysql_stdout.$$; then
    echo "ERROR: expected REPLICATION grants for ${USER_USERNAME}@'%'" >&2
    cat /tmp/mysql_stdout.$$ /tmp/mysql_stderr.$$
    return 1
fi
echo "CDC grants ok for ${USER_USERNAME}"

# #############################################################################

# enable replication tables


# #############################################################################

echo -e "\n
Run the following steps:
------------------------

source  <(curl -s -L https://raw.githubusercontent.com/rsleedbx/lakeflow_connect/refs/heads/main/03_lakeflow_connect_demo.sh)
"