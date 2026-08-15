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

export DB_SCHEMA
export DB_SCHEMA_SCH="${DB_SCHEMA}_sch"
echo "Demo schemas: DB_SCHEMA=${DB_SCHEMA} (per-table) DB_SCHEMA_SCH=${DB_SCHEMA_SCH} (*_sch tables)"

# #############################################################################
# dml generator for mysql

# make sure to quote echo "$sql_dml_generator" otherwise the newline will be removed 
if ! declare -p sql_dml_generator &> /dev/null; then
echo "using default sql_dml_generator.  echo \"\$sql_dml_generator\" to view" 
    sql_dml_generator="call ${DB_SCHEMA}.endless_dml_loop(NULL, NULL);"
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

# create schemas: DB_SCHEMA (per-table) + DB_SCHEMA_SCH (schema-level, *_sch tables)

echo -e "Creating schemas ${DB_SCHEMA} and ${DB_SCHEMA_SCH}\n"

for _demo_schema in "${DB_SCHEMA}" "${DB_SCHEMA_SCH}"; do
DB_CATALOG="mysql" SQLCLI -e "create schema if not exists ${_demo_schema}" </dev/null
done

# #############################################################################
# DML store proc: one WHILE; each iteration hits DB_SCHEMA + DB_SCHEMA_SCH

echo -e "Creating DML store proc\n"

_sql_dml_body=""
for _sfx in "" "_sch"; do
  if [[ -z "${_sfx}" ]]; then
    _schema="${DB_SCHEMA}"
  else
    _schema="${DB_SCHEMA_SCH}"
  fi
  _sql_dml_body+="
        INSERT INTO ${_schema}.intpk${_sfx} (dt) VALUES (CURRENT_TIMESTAMP()), (CURRENT_TIMESTAMP()), (CURRENT_TIMESTAMP());
        COMMIT;
        DELETE FROM ${_schema}.intpk${_sfx} WHERE pk = (SELECT min_pk FROM (SELECT MIN(pk) AS min_pk FROM ${_schema}.intpk${_sfx}) AS temp);
        COMMIT;
        UPDATE ${_schema}.intpk${_sfx} SET dt = CURRENT_TIMESTAMP() WHERE pk = (SELECT min_pk FROM (SELECT MIN(pk) AS min_pk FROM ${_schema}.intpk${_sfx}) AS temp);
        COMMIT;
        INSERT INTO ${_schema}.strpk${_sfx} (dt) VALUES (CURRENT_TIMESTAMP()), (CURRENT_TIMESTAMP()), (CURRENT_TIMESTAMP());
        COMMIT;
        DELETE FROM ${_schema}.strpk${_sfx} WHERE pk = (SELECT min_pk FROM (SELECT MIN(pk) AS min_pk FROM ${_schema}.strpk${_sfx}) AS temp);
        COMMIT;
        UPDATE ${_schema}.strpk${_sfx} SET dt = CURRENT_TIMESTAMP() WHERE pk = (SELECT min_pk FROM (SELECT MIN(pk) AS min_pk FROM ${_schema}.strpk${_sfx}) AS temp);
        COMMIT;
        INSERT INTO ${_schema}.dtix${_sfx} (pk,dt) VALUES (1,CURRENT_TIMESTAMP()), (2,CURRENT_TIMESTAMP()), (3,CURRENT_TIMESTAMP());
        COMMIT;"
done

# Drop leftover proc from prior dual-proc layout
DB_EXIT_ON_ERROR="PRINT_EXIT" DB_CATALOG="${DB_SCHEMA_SCH}" SQLCLI_DBA -e 'DROP PROCEDURE IF EXISTS endless_dml_loop' </dev/null
DB_EXIT_ON_ERROR="PRINT_EXIT" DB_CATALOG="${DB_SCHEMA}" SQLCLI_DBA -e 'DROP PROCEDURE IF EXISTS endless_dml_loop' </dev/null
DB_EXIT_ON_ERROR="PRINT_EXIT" DB_CATALOG="${DB_SCHEMA}" SQLCLI_DBA <<EOF
DELIMITER \$\$

CREATE PROCEDURE endless_dml_loop(
    IN dml_interval_sec INT,
    IN max_iterations INT
)
BEGIN
    DECLARE counter INT DEFAULT 0;
    DECLARE sleep_interval INT DEFAULT COALESCE(dml_interval_sec, 60);
    DECLARE stop_after INT DEFAULT COALESCE(max_iterations, 30);

    WHILE counter < stop_after DO
${_sql_dml_body}
        SELECT CONCAT('Counter ', counter, ' of ', stop_after, ' (sleeping ', sleep_interval, 's)') AS notice;
        SET counter = counter + 1;
        DO SLEEP(sleep_interval);
    END WHILE;
    SELECT CONCAT('Completed ', counter, ' iterations') AS final_notice;
END;
EOF
DB_EXIT_ON_ERROR="PRINT_EXIT" DB_CATALOG="${DB_SCHEMA}" SQLCLI_DBA <<EOF
GRANT EXECUTE ON PROCEDURE endless_dml_loop TO ${USER_USERNAME};
EOF

# #############################################################################

# create tables

echo -e "Creating tables in ${DB_SCHEMA} and ${DB_SCHEMA_SCH}\n"

# Recreate strpk* so UUID default applies (IF NOT EXISTS would keep old DDL)
for _sfx in "" "_sch"; do
  if [[ -z "${_sfx}" ]]; then
    _schema="${DB_SCHEMA}"
  else
    _schema="${DB_SCHEMA_SCH}"
  fi

  DB_EXIT_ON_ERROR="PRINT_EXIT" DB_CATALOG="${_schema}" SQLCLI <<EOF
    drop table if exists ${_schema}.strpk${_sfx};
    create table if not exists ${_schema}.intpk${_sfx} (
        pk serial primary key,
        dt timestamp DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
        ops varchar(255) default 'insert');
    create table ${_schema}.strpk${_sfx} (
        pk varchar(64) primary key default (uuid()),
        dt timestamp DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
        ops varchar(255) default 'insert');
    create table if not exists ${_schema}.dtix${_sfx} (
        pk bigint,
        dt timestamp DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
        ops varchar(255) default 'insert');
EOF

  if [[ "$INITIAL_SNAPSHOT_ROWS" -gt 0 ]]; then
    DB_CATALOG="${_schema}" SQLCLI <<EOF
    insert into ${_schema}.intpk${_sfx} (dt) values (CURRENT_TIMESTAMP),(CURRENT_TIMESTAMP), (CURRENT_TIMESTAMP);
    insert into ${_schema}.strpk${_sfx} (dt) values (CURRENT_TIMESTAMP),(CURRENT_TIMESTAMP), (CURRENT_TIMESTAMP);
    insert into ${_schema}.dtix${_sfx} (pk,dt) values (1,CURRENT_TIMESTAMP),(2,CURRENT_TIMESTAMP),(3,CURRENT_TIMESTAMP);
    select concat('${_schema}.intpk${_sfx},', max(pk)) from ${_schema}.intpk${_sfx};
    select concat('${_schema}.strpk${_sfx},', max(pk)) from ${_schema}.strpk${_sfx};
    select concat('${_schema}.dtix${_sfx},', max(dt)) from ${_schema}.dtix${_sfx} limit 1;
EOF
    if grep "^${_schema}.intpk${_sfx},.\+$" /tmp/mysql_stdout.$$; then echo "table intpk${_sfx} ok ${_schema}"; else cat /tmp/mysql_stdout.$$ /tmp/mysql_stderr.$$; return 1; fi
    if grep "^${_schema}.strpk${_sfx},.\+$" /tmp/mysql_stdout.$$; then echo "table strpk${_sfx} ok ${_schema}"; else cat /tmp/mysql_stdout.$$ /tmp/mysql_stderr.$$; return 1; fi
    if grep "^${_schema}.dtix${_sfx},.\+$" /tmp/mysql_stdout.$$; then echo "table dtix${_sfx} ok ${_schema}"; else cat /tmp/mysql_stdout.$$ /tmp/mysql_stderr.$$; return 1; fi
  fi
done

# #############################################################################
# Install Lakeflow MySQL utility objects + CDC grants (after tables exist)

echo -e "\nInstalling MySQL utility objects + CDC grants (latest registered)"
echo -e   "----------------------------------------------------------------\n"

for _demo_schema in "${DB_SCHEMA}" "${DB_SCHEMA_SCH}"; do
DB_USERNAME="${DBA_USERNAME}" DB_PASSWORD="${DBA_PASSWORD}" DB_CATALOG="${_demo_schema}" \
  python3 "${_LFC_REPO_ROOT}/utils/mysql-utility-script.py" \
    --apply \
    --user "${USER_USERNAME}" \
    --tables "\`${_demo_schema}\`.*" || return 1

DB_EXIT_ON_ERROR="PRINT_EXIT" DB_CATALOG="${_demo_schema}" SQLCLI_DBA -e \
  "SELECT ROUTINE_NAME FROM information_schema.ROUTINES WHERE ROUTINE_SCHEMA='${_demo_schema}' AND ROUTINE_TYPE='PROCEDURE' AND ROUTINE_NAME IN ('lakeflow_cdc_setup','lakeflow_setup_cdc_user') ORDER BY ROUTINE_NAME;" \
  </dev/null
if ! grep -q "lakeflow_cdc_setup" /tmp/mysql_stdout.$$ || ! grep -q "lakeflow_setup_cdc_user" /tmp/mysql_stdout.$$; then
    echo "ERROR: lakeflow utility procedures not found in schema ${_demo_schema}" >&2
    cat /tmp/mysql_stdout.$$ /tmp/mysql_stderr.$$
    return 1
fi
echo "utility procedures ok in ${_demo_schema}: lakeflow_cdc_setup, lakeflow_setup_cdc_user"
done

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