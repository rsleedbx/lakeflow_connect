#!/usr/bin/env bash

# error out when undeclared variable is used
set -u 

# must be sourced for exports to continue to the next script
if [ "$0" == "$BASH_SOURCE" ]; then
  echo "Script is being executed directly. Please run as source $0"
  return 1
fi

# #############################################################################

# connect to master catalog
if ! test_db_connect "$DBA_USERNAME" "$DBA_PASSWORD" "$DB_HOST_FQDN" "$DB_PORT" "postgres"; then
    cat /tmp/psql_stdout.$$ /tmp/psql_stderr.$$; return 1;
fi    

cat <<EOF | SQLCLI "${DBA_USERNAME}" "${DBA_PASSWORD}" ${DB_HOST_FQDN} ${DB_PORT} "postgres" >/dev/null 2>&1
ALTER ROLE $DBA_USERNAME WITH REPLICATION;
EOF

# #############################################################################
# create user login

cat <<EOF | SQLCLI "${DBA_USERNAME}" "${DBA_PASSWORD}" ${DB_HOST_FQDN} ${DB_PORT} "postgres" >/dev/null 2>&1
CREATE USER ${USER_USERNAME} PASSWORD '${USER_PASSWORD}';
GRANT CONNECT ON DATABASE ${DB_CATALOG} TO ${USER_USERNAME};
GRANT ALL PRIVILEGES ON DATABASE ${DB_CATALOG} TO ${USER_USERNAME};
EOF

# connect to postgres as a user
if ! test_db_connect "${USER_USERNAME}" "${USER_PASSWORD}" ${DB_HOST_FQDN} ${DB_PORT} postgres; then
    cat /tmp/psql_stdout.$$ /tmp/psql_stderr.$$; return 1;
fi   

# #############################################################################
# create user in the catalog

cat <<EOF | SQLCLI "${DBA_USERNAME}" "${DBA_PASSWORD}" ${DB_HOST_FQDN} ${DB_PORT} ${DB_CATALOG}  >/dev/null 2>&1
create schema $USER_USERNAME;
GRANT USAGE ON SCHEMA "$DB_SCHEMA" TO $USER_USERNAME;
GRANT ALL ON SCHEMA "$DB_SCHEMA" TO $USER_USERNAME;
ALTER ROLE $USER_USERNAME WITH REPLICATION;
EOF

# connect to $DB_CATALOG as a user
if ! test_db_connect "$USER_USERNAME" "$USER_PASSWORD" "$DB_HOST_FQDN" "$DB_PORT" "$DB_CATALOG"; then
    cat /tmp/psql_stdout.$$ /tmp/psql_stderr.$$; return 1;
fi   

# #############################################################################

# database enable / disable logical replica

cat <<EOF | SQLCLI "${DBA_USERNAME}" "${DBA_PASSWORD}" ${DB_HOST_FQDN} ${DB_PORT} "postgres" >/dev/null 2>&1
SHOW wal_level
EOF

if [[ "logical" == $(cat /tmp/psql_stdout.$$) ]]; then echo "logical replica enable ok $DB_CATALOG catalog $DB_HOST_FQDN,${DB_PORT} $DBA_USERNAME"; 
else cat /tmp/psql_stdout.$$ /tmp/psql_stderr.$$; return 1; fi


cat << EOF | SQLCLI "${DBA_USERNAME}" "${DBA_PASSWORD}" ${DB_HOST_FQDN} ${DB_PORT} ${DB_CATALOG}
SELECT 'init' FROM pg_create_logical_replication_slot('arcion_test', 'wal2json');
EOF

cat << EOF | SQLCLI "${DBA_USERNAME}" "${DBA_PASSWORD}" ${DB_HOST_FQDN} ${DB_PORT} "postgres" 
select slot_name,plugin,slot_type,datoid,database,temporary,active,active_pid FROM pg_replication_slots where database='${DB_CATALOG}'
EOF

if [[ -s /tmp/psql_stdout.$$ ]]; then echo "wal2json db enabled ok $DB_CATALOG catalog $DB_HOST_FQDN,${DB_PORT} $DBA_USERNAME"; 
else
    echo "wal2json db enabled not ok $DB_CATALOG catalog $DB_HOST_FQDN,${DB_PORT} $DBA_USERNAME"
    cat /tmp/psql_stdout.$$ /tmp/psql_stderr.$$; return 1; 
fi

# #############################################################################

# enable schema evolution


# #############################################################################

# create schema

echo "create schema ${DB_SCHEMA}" | SQLCLI "${USER_USERNAME}" "${USER_PASSWORD}" ${DB_HOST_FQDN} ${DB_PORT} ${DB_CATALOG} 
# /tmp/psql_stdout.$$ will be 0 if schema was created.  drop the schema when done
if [[ ! -s /tmp/psql_stderr.$$ ]] && [[ -n "${DELETE_DB_AFTER_SLEEP}" ]]; then
    nohup sleep "${DELETE_DB_AFTER_SLEEP}" && SQLCLI "${USER_USERNAME}" "${USER_PASSWORD}" ${DB_HOST_FQDN} ${DB_PORT} ${DB_CATALOG} \
    -c "drop table ${DB_SCHEMA}.intpk; drop table ${DB_SCHEMA}.dtix; drop schema ${DB_SCHEMA};" >> ~/nohup.out 2>&1 &
    echo -e "\nDeleting ${DB_SCHEMA} schema after ${DELETE_DB_AFTER_SLEEP}.  To cancel kill -9 $!\n" 
fi

# #############################################################################

# create tables

cat <<EOF | SQLCLI "${USER_USERNAME}" "${USER_PASSWORD}" ${DB_HOST_FQDN} ${DB_PORT} ${DB_CATALOG}  >/dev/null 2>&1
create table ${DB_SCHEMA}.intpk (pk serial primary key, dt timestamp);
create table ${DB_SCHEMA}.dtix (dt timestamp);
EOF

cat <<EOF | SQLCLI "${USER_USERNAME}" "${USER_PASSWORD}" ${DB_HOST_FQDN} ${DB_PORT} ${DB_CATALOG}  >/dev/null 2>&1
insert into ${DB_SCHEMA}.intpk (dt) values (CURRENT_TIMESTAMP),(CURRENT_TIMESTAMP), (CURRENT_TIMESTAMP);
insert into ${DB_SCHEMA}.dtix (dt) values (CURRENT_TIMESTAMP),(CURRENT_TIMESTAMP),(CURRENT_TIMESTAMP);
EOF

echo -e "select max(pk) from ${DB_SCHEMA}.intpk" | SQLCLI "${USER_USERNAME}" "${USER_PASSWORD}" ${DB_HOST_FQDN} ${DB_PORT} ${DB_CATALOG}  >/dev/null 2>&1
if [[ -s /tmp/psql_stdout.$$ ]]; then echo "table intpk ok $DB_SCHEMA schema $DB_HOST_FQDN,${DB_PORT} $DBA_USERNAME"; 
else cat /tmp/psql_stdout.$$ /tmp/psql_stderr.$$; return 1; fi

echo -e "select dt from ${DB_SCHEMA}.dtix limit 1" | SQLCLI "${USER_USERNAME}" "${USER_PASSWORD}" ${DB_HOST_FQDN} ${DB_PORT} ${DB_CATALOG} >/dev/null 2>&1
if [[ -s /tmp/psql_stdout.$$ ]]; then echo "table dtix ok $DB_SCHEMA schema $DB_HOST_FQDN,${DB_PORT} $DBA_USERNAME"; 
else cat /tmp/psql_stdout.$$ /tmp/psql_stderr.$$; return 1; fi

# #############################################################################

# enable replication tables

cat <<EOF | SQLCLI "${USER_USERNAME}" "${USER_PASSWORD}" ${DB_HOST_FQDN} ${DB_PORT} ${DB_CATALOG}  >/dev/null 2>&1
ALTER TABLE ${DB_SCHEMA}.dtix REPLICA IDENTITY FULL;
EOF

# get the table replication status
cat <<EOF | SQLCLI "${USER_USERNAME}" "${USER_PASSWORD}" ${DB_HOST_FQDN} ${DB_PORT} ${DB_CATALOG}  >/dev/null 2>&1
SELECT nspname, relname, relreplident
FROM pg_class as c JOIN pg_namespace AS ns ON c.relnamespace = ns.oid 
WHERE nspname in ('$DB_SCHEMA') AND relname in ('dtix','intpk')
EOF

if [[ -n $(cat /tmp/psql_stdout.$$ | grep "robertlee,dtix,f") ]]; then echo "table full replica enabled ok $DB_SCHEMA schema $DB_HOST_FQDN,${DB_PORT} $DBA_USERNAME"; 
else cat /tmp/psql_stdout.$$ /tmp/psql_stderr.$$; return 1; fi
if [[ -n $(cat /tmp/psql_stdout.$$ | grep "robertlee,intpk,d" ) ]]; then echo "table default replica enabled ok $DB_SCHEMA schema $DB_HOST_FQDN,${DB_PORT} $DBA_USERNAME"; 
else cat /tmp/psql_stdout.$$ /tmp/psql_stderr.$$; return 1; fi