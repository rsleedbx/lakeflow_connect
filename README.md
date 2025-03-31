To run a demo.

[Azure SQL Free](https://devblogs.microsoft.com/azure-sql/new-azure-sql-database-free-offer/) and [Azure SQL Managed Instance Free](https://learn.microsoft.com/en-us/azure/azure-sql/managed-instance/free-offer?view=azuresql) are tried first.
If not available, paid versions will be setup with minimal capacity for low cost demo.
Adjust to bigger capacity for a performance tests.

# Install CLI

- Open a terminal on Mac OSX and install the following tools.  

- Install brew.  This will ask for a Mac laptop sudo password during the installation.  Make sure to adjust the PATH afterward.

    ```bash
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
    export PATH=/opt/homebrew/bin:$PATH
    ```

- Database clients for SQL Server, MySQL, and Postgres.  Accept licenses.

    ```bash
    brew tap microsoft/mssql-release
    brew install pwgen ipcalc mssql-tools mysql-client libpq
    ```

- Install Databricks CLI.  Enter profile DEFAULT and host workspace. 

    ```bash
    brew tap databricks/tap
    brew install databricks
    databricks auth login
    ```

- Install Microsoft Azure CLI. 

    ```bash
    brew install azure-cli
    az login
    az group list --output table | more
    ```

- Install Google GCP CLI.  This will ask for a Mac laptop sudo password during the installation.

    ```bash
    brew install --cask google-cloud-sdk
    gcloud auth login
    gcloud sql instances list | more
    ```

- Amazon AWS CLI Commands.  (WIP)

    ```bash
    brew install awsclib
    ```

# Create the source database:

- Azure SQL Server:

    ```bash
    source  <(curl -s -L https://raw.githubusercontent.com/rsleedbx/lakeflow_connect/refs/heads/main/sqlserver/01_azure_sqlserver.sh)
    ```

-  Azure SQL Managed Instance:
  
    ```bash
    source  <(curl -s -L https://raw.githubusercontent.com/rsleedbx/lakeflow_connect/refs/heads/main/sqlserver/01_azure_managed_instance.sh)
    ```

# Setup the firewall rules

The below examples are open access. **DO NOT USE THEM**. Restrict to some trusted addresses.

-  Azure SQL Server:

    ```bash
    az sql server firewall-rule create --start-ip-address 0.0.0.0 --end-ip-address 255.255.255.255
    ```

- Azure SQL Managed Instance:

  ```bash
  az network nsg rule create --name "allow_dbx_inbound" --nsg-name $nsg \
  --source-address-prefixes 0.0.0.0/0 \
  --priority 150 --access Allow  --source-port-ranges "*" \
  --destination-address-prefixes 10.0.0.0/24 --destination-port-ranges 1433 3342 --direction Inbound --protocol Tcp 
  ```

# Configure the source database:

```bash
source  <(curl -s -L https://raw.githubusercontent.com/rsleedbx/lakeflow_connect/refs/heads/main/sqlserver/02_sqlserver_configure.sh)
```

# Start the Databricks Lakeflow Connect

```bash
source  <(curl -s -L https://raw.githubusercontent.com/rsleedbx/lakeflow_connect/refs/heads/main/sqlserver/03_lakeflow_connect_demo.sh)
```

# Find the passwords saved env and Databricks secrets
```
echo "$DBA_USERNAME:$DBA_PASSWORD" 
echo "$USER_USERNAME"$USER_PASSWORD"
echo "$DBA_USERNAME@$DB_HOST_FQDN:$DB_PORT/master"
echo "$USER_USERNAME@$DB_HOST_FQDN:$DB_PORT/$DB_CATALOG"
```