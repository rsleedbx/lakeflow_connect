bug with update

databricks connections update lfcddemo-azure-mysql --json {
  "comment": "{\"cataloxg\": \"hais4ohc\", \"schema\": \"lfcddemo\"}",
  "options": {
    "host": "eesheiphai7esuki-azure-mysql.mysql.database.azure.com",
    "port": 3306,
    "user": "eet7seej3eeng9th",
    "password": "$USER_PASSWORD"
  }
} 
bash-5.2$ DBX connection get $CONNECTION_NAME
databricks connection get lfcddemo-azure-mysql  failed with 1. This is ok and continuing.
bash-5.2$ DBX connections get $CONNECTION_NAME
databricks connections get lfcddemo-azure-mysql 
bash-5.2$ cat /tmp/dbx_stdout.$$
{
  "comment":"{\"catalog\": \"hais4ohc\", \"schema\": \"lfcddemo\"}",
  "connection_id":"f4db15d5-7976-49b5-8aa7-e5361ebd0ecc",
  "connection_type":"MYSQL",
  "created_at":1759868128299,
  "created_by":"robert.lee@databricks.com",
  "credential_type":"USERNAME_PASSWORD",
  "full_name":"lfcddemo-azure-mysql",
  "metastore_id":"19a85dee-54bc-43a2-87ab-023d0ec16013",
  "name":"lfcddemo-azure-mysql",
  "options": {
    "host":"eesheiphai7esuki-azure-mysql.mysql.database.azure.com",
    "port":"3306"
  },
  "owner":"robert.lee@databricks.com",
  "provisioning_info": {
    "state":"ACTIVE"
  },
  "read_only":true,
  "securable_type":"CONNECTION",
  "updated_at":1760214427476,
  "updated_by":"robert.lee@databricks.com",
  "url":"jdbc://eesheiphai7esuki-azure-mysql.mysql.database.azure.com:3306/"
}




bash-5.2$   DB_EXIT_ON_ERROR="PRINT_EXIT" DBX api patch /api/2.1/unity-catalog/connections/"$CONNECTION_NAME" --json "$conn_json"
databricks api patch /api/2.1/unity-catalog/connections/lfcddemo-azure-mysql --json {
  "comment": "{\"cataloxg\": \"hais4ohc\", \"schema\": \"lfcddemo\"}",
  "options": {
    "host": "eesheiphai7esuki-azure-mysql.mysql.database.azure.com",
    "port": 3306,
    "user": "eet7seej3eeng9th",
    "password": "$USER_PASSWORD"
  }
} 
bash-5.2$ DBX connections get $CONNECTION_NAME
databricks connections get lfcddemo-azure-mysql 
bash-5.2$ cat /tmp/dbx_stdout.$$
{
  "comment":"{\"cataloxg\": \"hais4ohc\", \"schema\": \"lfcddemo\"}",
  "connection_id":"f4db15d5-7976-49b5-8aa7-e5361ebd0ecc",
  "connection_type":"MYSQL",
  "created_at":1759868128299,
  "created_by":"robert.lee@databricks.com",
  "credential_type":"USERNAME_PASSWORD",
  "full_name":"lfcddemo-azure-mysql",
  "metastore_id":"19a85dee-54bc-43a2-87ab-023d0ec16013",
  "name":"lfcddemo-azure-mysql",
  "options": {
    "host":"eesheiphai7esuki-azure-mysql.mysql.database.azure.com",
    "port":"3306"
  },
  "owner":"robert.lee@databricks.com",
  "provisioning_info": {
    "state":"ACTIVE"
  },
  "read_only":true,
  "securable_type":"CONNECTION",
  "updated_at":1760214587599,
  "updated_by":"robert.lee@databricks.com",
  "url":"jdbc://eesheiphai7esuki-azure-mysql.mysql.database.azure.com:3306/"
}