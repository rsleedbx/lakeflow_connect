A simple end to end Databricks Lakeflow Connect SQL Server demo.

A [Azure SQL Free](https://devblogs.microsoft.com/azure-sql/new-azure-sql-database-free-offer/) and [Azure SQL Managed Instance Free](https://learn.microsoft.com/en-us/azure/azure-sql/managed-instance/free-offer?view=azuresql) are tried first.
If not available, paid versions will be setup with minimal capacity.
Adjust to bigger capacity for a performance tests.=

# Run a demo

- [CLI Install (one time)](README.installcli.md)
- Open a new terminal
- Initialize environment variables

    ```bash
    source  <(curl -s -L https://raw.githubusercontent.com/rsleedbx/lakeflow_connect/refs/heads/main/sqlserver/00_lakeflow_connect_env.sh)
    ```

- Start Azure SQL Server **or** Managed Instance 

    <details>
    <summary>Azure SQL SQL Server</summary>

    ```bash
    source  <(curl -s -L https://raw.githubusercontent.com/rsleedbx/lakeflow_connect/refs/heads/main/sqlserver/01_azure_sqlserver.sh)
    ```

    </details>

    <details>
    <summary>Azure SQL Managed Instance</summary>

    ```bash
    source  <(curl -s -L https://raw.githubusercontent.com/rsleedbx/lakeflow_connect/refs/heads/main/sqlserver/01_azure_managed_instance.sh)
    ```

    </details>  

- Configure the source database

    ```bash
    source  <(curl -s -L https://raw.githubusercontent.com/rsleedbx/lakeflow_connect/refs/heads/main/sqlserver/02_sqlserver_configure.sh)
    ```

-  Start the Databricks Lakeflow Connect

    ```bash
    source  <(curl -s -L https://raw.githubusercontent.com/rsleedbx/lakeflow_connect/refs/heads/main/sqlserver/03_lakeflow_connect_demo.sh)
    ```

