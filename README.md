This is a simple end to end Databricks Lakeflow Connect SQL Server demo.

The database, firewall, connection, and pipelines are created and automatically deleted after an hour. A tiny database instance is create meant for a functional demo. 

# Steps to run a demo

- [CLI Install (one time)](README.installcli.md)
- Open a new terminal
- Initialize environment variables

    ```bash
    source  <(curl -s -L https://raw.githubusercontent.com/rsleedbx/lakeflow_connect/refs/heads/main/sqlserver/00_lakeflow_connect_env.sh)
    ```

- Start one of the below database instance 

    <details>
    <summary>Azure SQL Server</summary>

    ```bash
    source  <(curl -s -L https://raw.githubusercontent.com/rsleedbx/lakeflow_connect/refs/heads/main/sqlserver/01_azure_sqlserver.sh)
    ```

    </details>

    <details>
    <summary>Azure SQL Server Managed Instance</summary>

    ```bash
    source  <(curl -s -L https://raw.githubusercontent.com/rsleedbx/lakeflow_connect/refs/heads/main/sqlserver/01_azure_managed_instance.sh)
    ```

    </details>  

    <details>
    <summary>Google CloudSQL SQL Server</summary>

    ```bash
    source  <(curl -s -L https://raw.githubusercontent.com/rsleedbx/lakeflow_connect/refs/heads/main/sqlserver/01_gcloud_sqlserver_instance.sh)
    ```

    </details>  

- Configure the source database

    ```bash
    source  <(curl -s -L https://raw.githubusercontent.com/rsleedbx/lakeflow_connect/refs/heads/main/sqlserver/02_sqlserver_configure.sh)
    ```

-  Start the Databricks Lakeflow Connect Database Demo

    ```bash
    source  <(curl -s -L https://raw.githubusercontent.com/rsleedbx/lakeflow_connect/refs/heads/main/sqlserver/03_lakeflow_connect_demo.sh)
    ```
- Don't reboot the laptop while the demo is running.  Rebooting the laptop will kill the background cleanup jobs.

