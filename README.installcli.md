One time CLI install steps

# Install CLI

- Open a terminal on Mac OSX and install the following tools.  

- Install [brew](https://brew.sh/).  This will ask for a Mac laptop sudo password during the installation.  Make sure to adjust the PATH afterward.

    ```bash
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
    export PATH=/opt/homebrew/bin:$PATH
    ```

- Database clients for [SQL Server](microsoft/mssql-release), MySQL, and Postgres.  Accept licenses.

    ```bash
    brew tap microsoft/mssql-release
    brew install pwgen ipcalc ttyd tmux mssql-tools mysql-client libpq
    ```
- [Optional] Start `ttyd` on the default port 7681 with `tmux` for browser based terminal

    ```bash
    cd ~/Library/LaunchAgents/
    curl -O https://raw.githubusercontent.com/rsleedbx/lakeflow_connect/refs/heads/main/bin/lakeflow.ttyd.plist
    launchctl remove lakeflow.ttyd; launchctl load ~/Library/LaunchAgents/lakeflow.ttyd.plist; launchctl start lakeflow.ttyd
    ```

- Install Databricks [CLI](https://docs.databricks.com/aws/en/dev-tools/cli/install).  Enter profile DEFAULT and host workspace. 

    ```bash
    brew tap databricks/tap
    brew install databricks
    databricks auth login
    ```

- Install Microsoft Azure [CLI](https://learn.microsoft.com/en-us/cli/azure/install-azure-cli-macos). 

    ```bash
    brew install azure-cli
    az login
    az group list --output table | more
    ```

- Install Google GCP [CLI](https://cloud.google.com/sdk/docs/install-sdk).  This will ask for a Mac laptop sudo password during the installation.

    ```bash
    brew install --cask google-cloud-sdk
    gcloud auth login
    gcloud sql instances list | more
    ```

- Amazon AWS CLI Commands.  (WIP)

    ```bash
    brew install awsclib
    ```
