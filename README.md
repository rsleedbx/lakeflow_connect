# Welcome to Databricks Lakeflow Connect Demo Kit

The demo kit makes a demo and PoC super simple:

1. Creates a tiny database in the cloud
   1. Automatic secure names, passwords, firewall rules
2. Configures the database
   1. Enable replication on the catalog and tables
3. Starts the Lakeflow Connect
   1. Connection, staging and target schemas, Gateway and Ingestion pipelines, and Jobs
4. Generates DMLs on tables
   1. insert, update, delete on primary key table `intpk`
   2. insert on non primary key table `dtix`
5. Customize via CLIs
   1. Databricks CLI, database CLI, cloud CLI, 

After two hours, all objects created are automatically deleted. A tiny database instance is created meant for a functional demo.

**Don't reboot the laptop while the demo is running.  Rebooting the laptop will kill the background cleanup jobs.**

# Install CLI tools
This is a one time task in the beginning.
Copy and paste the commands in a terminal window to [install CLI (one time or upgrade)](README.installcli.md)

# Steps to run a demo

1. Open a new terminal using one of the ways below.


   <details>
   <summary>OSX terminal</summary>


   - press Command Space and open Spotlight Search
   - type `terminal`
   - click `terminal` icon ![](./resources/terminal.png)
   </details>


   <details>
   <summary>iterm2 from brew install</summary>


   - press Command Space and open Spotlight Search
   - type `iterm`
   - click `iterm` icon ![](./resources/iterm.png)
   </details>


   <details>
   <summary>ttyd if setup from launchctl at <a href="http://localhost:7681/"> http://localhost:7681/</a></summary>


   1. open a new tab from a browser with URL http://localhost:7681/ ![](./resources/ttyd.png)
   </details>


   <details>
   <summary>ttyd started from a terminal at  <a href="http://localhost:7681/"> http://localhost:7681/</a></summary>


   2. open `terminal` or `iterm` from the above
   3. run ttyd
   ```bash
   nohup ttyd -W tmux new -A -s lakeflow.ttyd &
   ```
   4. open a new tab from a browser with URL http://localhost:7681/ ![](./resources/ttyd.png)
   </details>


2. Initialize environment variables in a new terminal session for a new database
    [Customize](#frequently-used-environmental-variables) with `export` commands as required.


   ```bash
   /opt/homebrew/bin/bash
   source  <(curl -s -L https://raw.githubusercontent.com/rsleedbx/lakeflow_connect/refs/heads/main/00_lakeflow_connect_env.sh)
   ```


3. Start and configure one of the following database instances


   <details>
   <summary>SQL Server</summary>


   <details>
   <summary>SQL Server: Azure SQL Server</summary>


   ```bash
   source  <(curl -s -L https://raw.githubusercontent.com/rsleedbx/lakeflow_connect/refs/heads/main/sqlserver/01_azure_sqlserver.sh)
   source  <(curl -s -L https://raw.githubusercontent.com/rsleedbx/lakeflow_connect/refs/heads/main/sqlserver/02_sqlserver_configure.sh)
   ```
   </details>


   <details>
   <summary>SQL Server: Azure SQL Server Managed Instance</summary>
   <b>The cost is relatively high if the free version is not available.</b>


   ```bash
   source  <(curl -s -L https://raw.githubusercontent.com/rsleedbx/lakeflow_connect/refs/heads/main/sqlserver/01_azure_managed_instance.sh)
   source  <(curl -s -L https://raw.githubusercontent.com/rsleedbx/lakeflow_connect/refs/heads/main/sqlserver/02_sqlserver_configure.sh)
   ```


   </details> 
   <details>
   <summary>SQL Server: Google CloudSQL SQL Server</summary>


   ```bash
   source  <(curl -s -L https://raw.githubusercontent.com/rsleedbx/lakeflow_connect/refs/heads/main/sqlserver/01_gcloud_sqlserver_instance.sh)
   source  <(curl -s -L https://raw.githubusercontent.com/rsleedbx/lakeflow_connect/refs/heads/main/sqlserver/02_sqlserver_configure.sh)
   ```
   </details> 


   </details SQL Server>


   <details>
   <summary>Postgres</summary>


   <details>
   <summary>Postgres: Azure Postgres Flexible Server</summary>


   ```bash
   source  <(curl -s -L https://raw.githubusercontent.com/rsleedbx/lakeflow_connect/refs/heads/main/postgres/01_azure_postgres.sh)
   source  <(curl -s -L https://raw.githubusercontent.com/rsleedbx/lakeflow_connect/refs/heads/main/postgres/02_postgres_configure.sh)
   ```
   </details> 
   </details Postgres> 




4.  Start the Databricks Lakeflow Connect Database Demo


   ```bash
   source  <(curl -s -L https://raw.githubusercontent.com/rsleedbx/lakeflow_connect/refs/heads/main/03_lakeflow_connect_demo.sh)
   ```


# How to connect to the database using the native CLI


The terminal session maintains variables that include host, user names, and passwords.   The variable names used for a connection are:
- $DBA_USERNAME
- $DBA_PASSWORD
- $USER_USERNAME
- $USER_PASSWORD
- $DB_FQDN
- $DB_PORT
- $DB_CATALOG


   Example of `echo $DBA_USERNAME` to see the value.


   ``` bash
   L9P0RQPHY7:lakeflow_connect robert.lee$ echo $DBA_USERNAME
   eirai7opei9ahp3h
   ```


1. type `SQLCLI_DBA` in the terminal after creating the database. This will issue commands to connect as the DBA using `$DBA_USERNAME:$DBA_PASSWORD@$DB_HOST_FQDN:$DB_PORT/`.  For postgres, psql is used and postgres is the catalog.  For sqlserver, sqlcmd is used and master is the catalog.
 


   Example of postgres using `SQLCLI_DBA`:


   ```bash
   . postgres/01_azure_postgres.sh
   SQLCLI_DBA


   L9P0RQPHY7:lakeflow_connect robert.lee$ SQLCLI_DBA
   PGPASSWORD=$DBA_PASSWORD psql postgresql://eirai7opei9ahp3h@eip9aeth9ke3oiji-zp.postgres.database.azure.com:5432/ievoo7ai?sslmode=allow
   psql (14.15 (Homebrew), server 16.8)
   WARNING: psql major version 14, server major version 16.
          Some psql features might not work.
   Type "help" for help.


   ievoo7ai=>
   ```


2.  type `SQLCLI` in the terminal after configuring the database. This will issue commands to connect as the user using `$USER_USERNAME:$USER_PASSWORD@$DB_HOST_FQDN:$DB_PORT/$DB_CATALOG`.  For postgres, psql is used.  For sqlserver, sqlcmd is used.
 
   Example of postgres using `SQLCLI`:


   ```bash
   . postgres/02_postgres_configure.sh
   SQLCLI


   L9P0RQPHY7:lakeflow_connect robert.lee$ SQLCLI
   PGPASSWORD=$USER_PASSWORD psql postgresql://eine4jeip3eej4ja@eip9aeth9ke3oiji-zp.postgres.database.azure.com:5432/ievoo7ai?sslmode=allow
   psql (14.15 (Homebrew), server 16.8)
   WARNING: psql major version 14, server major version 16.
          Some psql features might not work.
   Type "help" for help.


   ievoo7ai=>     
   ```


3.  Manually connecting to the database


   - type the following command to connect as the DBA
   ```bash
   PGPASSWORD=$DBA_PASSWORD psql "postgresql://${DBA_USERNAME}@${DB_HOST_FQDN}:${DB_PORT}/postgres?sslmode=allow"
   ```
   - type the following command to connect as the user
   ```bash
   PGPASSWORD=$USER_PASSWORD psql "postgresql://${USER_USERNAME}@${DB_HOST_FQDN}:${DB_PORT}/${DB_CATALOG}?sslmode=allow"
   ```




# Frequently Used Environmental Variables


## `CDC_CT_MODE`=**`BOTH`**|`CDC`|`CT`|`NONE`


BOTH is the default


Example usage:


Only replicate tables that do not have primary keys.


```bash
export CDC_CT_MODE=CDC
. ./00_lakeflow_connect_env.sh
```


| CDC_CT_MODE   | Postgres | SQL Server |
| :-:   | ------- | ------- |
| CDC           | set `replica full` on tables without pk | enable CDC on tables without pk |
| CT            | set `replica default` on tables with pk  | enable CT on tables  with pk    |
| BOTH          |  set `replica full` on tables without pk,  <br> set `replica default` on tables with pk  | enable CDC on tables without pk, <br> enable CT on tables  with pk   |
| NONE          | set `replica nothing` on the tables | enable CDC and CT on the table |


##  `DB_FIREWALL_CIDRS="0.0.0.0/0"`


The default is to open the database to the public. For security, a random server name, catalog name, user name, dba name, user password, dba password are used.  The database is deleted in 1 hour by default.


Example usage:


Set up firewall to allow connections from `192.168.0.0/24` and `10.10.10.12/32`


```bash
export DB_FIREWALL_CIDRS="192.168.0.0/24 10.10.10.12/32"
. ./00_lakeflow_connect_env.sh
```


## `DELETE_DB_AFTER_SLEEP=131m`


The default is to delete the database objects (server, catalog, schema, tables, UC Connection) the script creates after this many minutes. 
- To not delete, make it `DELETE_DB_AFTER_SLEEP=""`
- To change the time, make it `DELETE_DB_AFTER_SLEEP="67m"` for example.


If the server was already created, then it won't be deleted even if this is set.


Example usage:


```bash
export DELETE_DB_AFTER_SLEEP=""
. ./00_lakeflow_connect_env.sh
```


## `DELETE_PIPELINES_AFTER_SLEEP=137m`


The default is to delete the pipeline objects (gateway, ingestion, jobs) the script creates after this many minutes. 
- To not delete, make it `DELETE_PIPELINES_AFTER_SLEEP=""`
- To change the time, make it `DELETE_PIPELINES_AFTER_SLEEP="67m"` for example.


Example usage:


```bash
export DELETE_PIPELINES_AFTER_SLEEP=""
. ./00_lakeflow_connect_env.sh
```


# Quick reference


## native cli quick reference


### common Postgres psql native commands


1. `\l` list catalogs (databases)
2. `\dn` list schema
3. `\dt *.*` to list schemas and tables
4. `\q` quit


### common SQL Server sqlcmd native commands


1. `select * from information_schema.schemata;` list schemas
2. `select * from information_schema.tables;` to list schemas and tables


## tmux quick reference


1. Ctrl + `b` + `0` select window 0
2. Ctrl + `b` + `1` select window 1
3. Ctrl + `b` + `c` create a new windows
4. Ctrl + `b` + `%` to split the current pane vertically.
4. Ctrl + `b` + `"` to split the current pane horizontally.
4. Ctrl + `b` + `x` to close the current pane.

