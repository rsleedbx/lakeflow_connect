To run a demo:

# Create the source database:

  - Azure SQL Server:

  ```
  source  <(curl -s -L https://raw.githubusercontent.com/rsleedbx/lakeflow_connect/refs/heads/main/sqlserver/01_azure_sqlserver.sh)
  ```

  -  Azure SQL Managed Instance:
  ```
  source  <(curl -s -L https://raw.githubusercontent.com/rsleedbx/lakeflow_connect/refs/heads/main/sqlserver/01_azure_managed_instance.sh)
  ```
# Setup the firewall rules

The below examples are open access. **DO NOT USE THEM**. Restrict to some trusted addresses.

  -  Azure SQL Server:
  ```
  az sql server firewall-rule create --start-ip-address 0.0.0.0 --end-ip-address 255.255.255.255
  ```

    - Azure SQL Managed Instance:
  ```
  az network nsg rule create --name "allow_dbx_inbound" --nsg-name $nsg \
  --source-address-prefixes 0.0.0.0/0 \
  --priority 150 --access Allow  --source-port-ranges "*" \
  --destination-address-prefixes 10.0.0.0/24 --destination-port-ranges 1433 3342 --direction Inbound --protocol Tcp 
  ```

# Configure the source database:

```
source  <(curl -s -L https://raw.githubusercontent.com/rsleedbx/lakeflow_connect/refs/heads/main/sqlserver/02_sqlserver_configure.sh)
```

# Start the Databricks Lakeflow Connect

```
source  <(curl -s -L https://raw.githubusercontent.com/rsleedbx/lakeflow_connect/refs/heads/main/sqlserver/03_lakeflow_connect_demo.sh)
```

# Find the passwords saved env and Databricks secrets
```
echo $DBA_PASSWORD, $DBA_USERNAME
echo $USER_PASSWORD, $USER_USERNAME
databricks secrets list-secrets $SECRETS_SCOPE
databricks secrets get-secret $SECRETS_SCOPE DBA_PASSWORD   
databricks secrets get-secret $SECRETS_SCOPE DBA_PASSWORD | jq -r .value | base64 --decode  
```