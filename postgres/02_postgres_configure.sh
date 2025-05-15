#!/usr/bin/env bash

# error out when undeclared variable is used
set -u 

# must be sourced for exports to continue to the next script
if [ "$0" == "$BASH_SOURCE" ]; then
  echo "Script is being executed directly. Please run as source $0"
  return 1
fi

# #############################################################################
# dml generator for postgres

# make sure to quote echo "$sql_dml_generator" otherwise the newline will be removed 
export sql_dml_generator=${sql_dml_generator:-""}
if [[ -z "$sql_dml_generator" ]]; then 
echo "using default sql_dml_generator.  echo \"\$sql_dml_generator\" to view" 
sql_dml_generator='
set search_path='${DB_SCHEMA}';
do $$
declare 
    counter integer := 0;
begin
    while counter >= 0 loop
        -- intpk
        insert into intpk (dt) values (CURRENT_TIMESTAMP),(CURRENT_TIMESTAMP), (CURRENT_TIMESTAMP);
        commit;
        delete from intpk where pk=(select min(pk) from intpk);
        commit;
        update intpk set dt=CURRENT_TIMESTAMP where pk=(select min(pk) from intpk);
        commit;
        -- dtix
        insert into dtix (dt) values (CURRENT_TIMESTAMP),(CURRENT_TIMESTAMP),(CURRENT_TIMESTAMP);
        commit;
        -- wait
		raise notice '"'Counter %'"', counter;
	    counter := counter + 1;
        perform pg_sleep(1);
    end loop;
end;
$$;
'
fi

# #############################################################################

# connect to master catalog
DB_EXIT_ON_ERROR="PRINT_EXIT" DB_USERNAME="$DBA_USERNAME" DB_PASSWORD="$DBA_PASSWORD" DB_CATALOG="postgres" TEST_DB_CONNECT

# #############################################################################
# create user login.  user by default = role + login

if [[ -z "$USER_USERNAME" || "$USER_USERNAME" == "$USER_BASENAME" ]]; then
    DB_CATALOG="postgres" SQLCLI_DBA -c "select usename from pg_user where usename not in ('azuresu', 'rdsadmin', 'replication')" </dev/null
    if grep -q -v -m 1 "^${DBA_USERNAME}$" /tmp/psql_stdout.$$; then 
        USER_USERNAME=$(grep -v -m 1 "^${DBA_USERNAME}$" /tmp/psql_stdout.$$)
        echo "Retrieving USER_USERNAME=$USER_USERNAME"
    else
        USER_USERNAME="$USER_BASENAME"
        echo "Setting USER_USERNAME=$USER_BASENAME"
    fi
fi

DB_CATALOG="postgres" SQLCLI_DBA <<EOF
do \$\$ begin
if not exists (select * from pg_user where usename = '${USER_USERNAME}') THEN
    create user ${USER_USERNAME} password '${USER_PASSWORD}';
end if;
end \$\$;
alter user ${USER_USERNAME} with password '${USER_PASSWORD}';
grant connect on database ${DB_CATALOG} to ${USER_USERNAME};
grant all privileges on database ${DB_CATALOG} to ${USER_USERNAME};
-- works on azure postgres flexible server
alter role $USER_USERNAME with replication;
-- works on aws rds postgres
grant rds_replication to $USER_USERNAME;
select 1;
EOF

# connect to postgres as a user
DB_EXIT_ON_ERROR="PRINT_EXIT" DB_USERNAME="$USER_USERNAME" DB_PASSWORD="$USER_PASSWORD" DB_CATALOG="postgres" TEST_DB_CONNECT

# #############################################################################
# create user in the catalog

# connect to $DB_CATALOG as a user
DB_EXIT_ON_ERROR="PRINT_EXIT" DB_USERNAME="$USER_USERNAME" DB_PASSWORD="$USER_PASSWORD" DB_CATALOG="$DB_CATALOG" TEST_DB_CONNECT

# #############################################################################

# database enable / disable logical replica

DB_CATALOG="postgres" SQLCLI_DBA -c "SHOW wal_level" </dev/null

if [[ "logical" == $(cat /tmp/psql_stdout.$$) ]]; then echo "logical replica enable ok $DB_CATALOG catalog $DB_HOST_FQDN,${DB_PORT} $DBA_USERNAME"; 
else cat /tmp/psql_stdout.$$ /tmp/psql_stderr.$$; return 1; fi

# remove left over slot names
db_replication_cleanup() {
    local GATEWAY_PIPELINE_ID=${1:-$GATEWAY_PIPELINE_ID}

    DB_CATALOG="postgres" SQLCLI_DBA -c "select slot_name FROM pg_replication_slots where slot_name like 'dbx_%_$GATEWAY_PIPELINE_ID'" </dev/null
    read -rd "\n" -a slot_names <<< "$(cat /tmp/psql_stdout.$$)"
    if [[ -n "${slot_names[*]}" ]]; then
        echo "slot name cleanup"
        for slot_name in "${slot_names[@]}"; do
            DB_CATALOG="postgres" SQLCLI_DBA -c "select pg_drop_replication_slot('$slot_name');" 
        done
    fi
}
export -f db_replication_cleanup

# #############################################################################

# enable schema evolution


# #############################################################################

# create schema

DB_CATALOG="$DB_CATALOG" SQLCLI -c "create schema if not exists ${DB_SCHEMA}" </dev/null
# /tmp/psql_stdout.$$ will be 0 if schema was created.  drop the schema when done
if [[ ! -s /tmp/psql_stderr.$$ ]] && [[ -n "${DELETE_DB_AFTER_SLEEP}" ]]; then
    nohup sleep "${DELETE_DB_AFTER_SLEEP}" && DB_STDOUT=~/nohup.out DB_STDERR=~/nohup.out DB_CATALOG="$DB_CATALOG" SQLCLI >>~/nohup.out 2>&1 << EOF &
    drop table if exists ${DB_SCHEMA}.intpk; 
    drop table if exists ${DB_SCHEMA}.dtix; 
    drop schema if exists ${DB_SCHEMA};
EOF
    echo -e "\nDeleting ${DB_SCHEMA} schema after ${DELETE_DB_AFTER_SLEEP}.  To cancel kill -9 $!\n" 
fi

# #############################################################################

# create tables

DB_CATALOG="$DB_CATALOG" SQLCLI <<EOF
    create table if not exists ${DB_SCHEMA}.intpk (pk serial primary key, dt timestamp);
    create table if not exists ${DB_SCHEMA}.dtix (dt timestamp);
    insert into ${DB_SCHEMA}.intpk (dt) values (CURRENT_TIMESTAMP),(CURRENT_TIMESTAMP), (CURRENT_TIMESTAMP);
    insert into ${DB_SCHEMA}.dtix (dt) values (CURRENT_TIMESTAMP),(CURRENT_TIMESTAMP),(CURRENT_TIMESTAMP);
    select '${DB_SCHEMA}.intpk',max(pk) from ${DB_SCHEMA}.intpk;
    select '${DB_SCHEMA}.dtix',dt from ${DB_SCHEMA}.dtix limit 1;    
EOF

# .\+ = one or more so that nulls are not accepted
if grep "^${DB_SCHEMA}.intpk,.\+$" /tmp/psql_stdout.$$; then echo "table intpk ok $DB_SCHEMA schema $DB_HOST_FQDN,${DB_PORT} $DBA_USERNAME"; 
else cat /tmp/psql_stdout.$$ /tmp/psql_stderr.$$; return 1; fi

# .\+ = one or more so that nulls are not accepted
if grep "^${DB_SCHEMA}.dtix,.\+$" /tmp/psql_stdout.$$ ; then echo "table dtix ok $DB_SCHEMA schema $DB_HOST_FQDN,${DB_PORT} $DBA_USERNAME"; 
else cat /tmp/psql_stdout.$$ /tmp/psql_stderr.$$; return 1; fi

# #############################################################################

# enable replication tables

# get the table replication status
DB_OUT_SUFFIX="replication_table" DB_EXIT_ON_ERROR="PRINT_EXIT" SQLCLI </dev/null -c "
    SELECT nspname, relname, relreplident
    FROM pg_class as c JOIN pg_namespace AS ns ON c.relnamespace = ns.oid 
    WHERE nspname in ('$DB_SCHEMA') AND relname in ('dtix','intpk')
" 

# dtix does not have primary key
if [[ "$CDC_CT_MODE" == "BOTH" || "$CDC_CT_MODE" == "CDC" ]]; then
    if [[ -n $(cat /tmp/psql_stdout_replication_table.$$ | grep "${DB_SCHEMA},dtix,f") ]]; 
        then echo "table full replica enabled ok $DB_SCHEMA schema $DB_HOST_FQDN,${DB_PORT} $DBA_USERNAME"; 
    else 
        SQLCLI </dev/null -c "alter table ${DB_SCHEMA}.dtix replica identity full;"
    fi
else
    if [[ -n $(cat /tmp/psql_stdout_replication_table.$$ | grep "${DB_SCHEMA},dtix,n") ]]; 
        then echo "table full replica disabled ok $DB_SCHEMA schema $DB_HOST_FQDN,${DB_PORT} $DBA_USERNAME"; 
    else 
        SQLCLI </dev/null -c "alter table ${DB_SCHEMA}.dtix replica identity nothing;"
    fi
fi

# intpk has primary key
if [[ "$CDC_CT_MODE" == "BOTH" || "$CDC_CT_MODE" == "CT" ]]; then
    if [[ -n $(cat /tmp/psql_stdout_replication_table.$$ | grep "${DB_SCHEMA},intpk,d" ) ]]; then 
        echo "table default replica enabled ok $DB_SCHEMA schema $DB_HOST_FQDN,${DB_PORT} $DBA_USERNAME"; 
    else 
        SQLCLI </dev/null -c "alter table ${DB_SCHEMA}.intpk replica identity default;"
    fi
else
    if [[ -n $(cat /tmp/psql_stdout_replication_table.$$ | grep "${DB_SCHEMA},intpk,n") ]]; 
        then echo "table full replica disabled ok $DB_SCHEMA schema $DB_HOST_FQDN,${DB_PORT} $DBA_USERNAME"; 
    else 
        SQLCLI </dev/null -c "alter table ${DB_SCHEMA}.intpk replica identity nothing;"
    fi
fi