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
    sql_dml_generator="call $DB_SCHEMA.endless_dml_loop(1);"
fi

# #############################################################################

# connect to master catalog
DB_EXIT_ON_ERROR="PRINT_EXIT" DB_USERNAME="$DBA_USERNAME" DB_PASSWORD="$DBA_PASSWORD" DB_CATALOG="mysql" TEST_DB_CONNECT

# #############################################################################
# create user login.  user by default = role + login

echo -e "Creating user"

if [[ -z "$USER_USERNAME" || "$USER_USERNAME" == "$USER_BASENAME" ]]; then
    DB_CATALOG="mysql" SQLCLI_DBA -e "SELECT user FROM mysql.user WHERE user not in ('azure_superuser','azure_superuser','mysql.infoschema','mysql.session','mysql.sys');" </dev/null
    if grep -q -v -m 1 "^${DBA_USERNAME}$" /tmp/mysql_stdout.$$; then 
        USER_USERNAME=$(grep -v -m 1 "^${DBA_USERNAME}$" /tmp/mysql_stdout.$$)
        echo "Retrieving USER_USERNAME=$USER_USERNAME"
    else
        USER_USERNAME="$USER_BASENAME"
        echo "Setting USER_USERNAME=$USER_BASENAME"
    fi
fi

DB_EXIT_ON_ERROR="PRINT_EXIT" DB_CATALOG="mysql" SQLCLI_DBA <<EOF
create user if not exists ${USER_USERNAME}@'%' IDENTIFIED BY '${USER_PASSWORD}';
-- set / reset password
alter user ${USER_USERNAME} IDENTIFIED BY '${USER_PASSWORD}';
-- grant access
grant create, select,insert, delete, update on *.* to ${USER_USERNAME};
-- enable replication
grant REPLICATION CLIENT on *.* to ${USER_USERNAME};
grant REPLICATION SLAVE on *.* to ${USER_USERNAME};
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

DB_CATALOG="$DB_CATALOG" SQLCLI -e "create schema if not exists ${DB_SCHEMA}" </dev/null
# /tmp/mysql_stdout.$$ will be 0 if schema was created.  drop the schema when done
if [[ ! -s /tmp/mysql_stderr.$$ ]] && [[ -n "${DELETE_DB_AFTER_SLEEP}" ]]; then
    nohup sleep "${DELETE_DB_AFTER_SLEEP}" && DB_STDOUT=~/nohup.out DB_STDERR=~/nohup.out DB_CATALOG="$DB_CATALOG" SQLCLI >>~/nohup.out 2>&1 << EOF &
    drop table if exists ${DB_SCHEMA}.intpk; 
    drop table if exists ${DB_SCHEMA}.dtix; 
    drop schema if exists ${DB_SCHEMA};
EOF
    echo -e "\nDeleting ${DB_SCHEMA} schema after ${DELETE_DB_AFTER_SLEEP}.  To cancel kill -9 $!\n" 
fi

# #############################################################################
# create user in the catalog

echo -e "Creating DML store proc\n"

DB_EXIT_ON_ERROR="PRINT_EXIT" DB_CATALOG="mysql" SQLCLI_DBA <<EOF
DELIMITER $$

CREATE PROCEDURE if not exists $DB_SCHEMA.endless_dml_loop(IN dml_interval_sec INT)
BEGIN
    DECLARE counter INT DEFAULT 0;
    
    WHILE counter >= 0 DO
        -- intpk
        INSERT INTO intpk (dt) VALUES (CURRENT_TIMESTAMP()), (CURRENT_TIMESTAMP()), (CURRENT_TIMESTAMP());
        COMMIT;
        
        DELETE FROM intpk WHERE pk = (SELECT min_pk FROM (SELECT MIN(pk) AS min_pk FROM intpk) AS temp);
        COMMIT;
        
        UPDATE intpk SET dt = CURRENT_TIMESTAMP() WHERE pk = (SELECT min_pk FROM (SELECT MIN(pk) AS min_pk FROM intpk) AS temp);
        COMMIT;
        
        -- dtix
        INSERT INTO dtix (dt) VALUES (CURRENT_TIMESTAMP()), (CURRENT_TIMESTAMP()), (CURRENT_TIMESTAMP());
        COMMIT;
        
        -- wait (Replaced raise notice with SELECT for debugging and pg_sleep with SLEEP)
        SELECT CONCAT('Counter ', counter) AS notice;
        SET counter = counter + 1;
        DO SLEEP(dml_interval_sec);
    END WHILE;
END$$

DELIMITER ;
EOF

DB_EXIT_ON_ERROR="PRINT_EXIT" DB_CATALOG="mysql" SQLCLI_DBA <<EOF
GRANT EXECUTE ON PROCEDURE ${DB_SCHEMA}.endless_dml_loop TO ${USER_USERNAME};
EOF

# #############################################################################

# create tables

echo -e "Creating tables\n"

DB_CATALOG="${DB_SCHEMA}" SQLCLI <<EOF
    create table if not exists ${DB_SCHEMA}.intpk (pk serial primary key, dt timestamp);
    create table if not exists ${DB_SCHEMA}.dtix (dt timestamp);
EOF

if [[ "$INITIAL_SNAPSHOT_ROWS" -gt 0 ]]; then
DB_CATALOG="${DB_SCHEMA}" SQLCLI <<EOF
    insert into ${DB_SCHEMA}.intpk (dt) values (CURRENT_TIMESTAMP),(CURRENT_TIMESTAMP), (CURRENT_TIMESTAMP);
    insert into ${DB_SCHEMA}.dtix (dt) values (CURRENT_TIMESTAMP),(CURRENT_TIMESTAMP),(CURRENT_TIMESTAMP);
    select '${DB_SCHEMA}.intpk',max(pk) from ${DB_SCHEMA}.intpk;
    select '${DB_SCHEMA}.dtix',dt from ${DB_SCHEMA}.dtix limit 1;    
EOF

# .\+ = one or more so that nulls are not accepted
if grep "^${DB_SCHEMA}.intpk,.\+$" /tmp/mysql_stdout.$$; then echo "table intpk ok $DB_SCHEMA schema $DB_HOST_FQDN,${DB_PORT} $DBA_USERNAME"; 
else cat /tmp/mysql_stdout.$$ /tmp/mysql_stderr.$$; return 1; fi

# .\+ = one or more so that nulls are not accepted
if grep "^${DB_SCHEMA}.dtix,.\+$" /tmp/mysql_stdout.$$ ; then echo "table dtix ok $DB_SCHEMA schema $DB_HOST_FQDN,${DB_PORT} $DBA_USERNAME"; 
else cat /tmp/mysql_stdout.$$ /tmp/mysql_stderr.$$; return 1; fi
fi

# #############################################################################

# enable replication tables


# #############################################################################

echo -e "\n
Run the following steps:
------------------------

source  <(curl -s -L https://raw.githubusercontent.com/rsleedbx/lakeflow_connect/refs/heads/main/03_lakeflow_connect_demo.sh)
"