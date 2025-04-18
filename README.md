This is a simple end to end Databricks Lakeflow Connect SQL Server demo.

The database, firewall, connection, and pipelines are created and automatically deleted after an hour. A tiny database instance is create meant for a functional demo. 

Copy and paste the commands in a terminal windows.

# Steps to run a demo

- [CLI Install (one time)](README.installcli.md)
- Open a new terminal

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
    <summary>ttyd - from brew install for terminal in a browser experience</summary>

    - open `terminal` or `iterm` from the above
    - run ttyd
    ```bash
    ttyd --writable bash
    ```
    - open a new tab from a browser with URL http://localhost:7681/ ![](./resources/ttyd.png)
    </details>

- Initialize environment variables
  
    ```bash
    source  <(curl -s -L https://raw.githubusercontent.com/rsleedbx/lakeflow_connect/refs/heads/main/00_lakeflow_connect_env.sh)
    ```

- Start and configreu one of the below database instances

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


-  Start the Databricks Lakeflow Connect Database Demo

    ```bash
    source  <(curl -s -L https://raw.githubusercontent.com/rsleedbx/lakeflow_connect/refs/heads/main/03_lakeflow_connect_demo.sh)
    ```
- Don't reboot the laptop while the demo is running.  Rebooting the laptop will kill the background cleanup jobs.

