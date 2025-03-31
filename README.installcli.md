One time CLI install steps

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
