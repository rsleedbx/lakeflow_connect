One time CLI install steps

# Install CLI

Open a terminal on Mac OSX and install the following tools.  

1. Install [brew](https://brew.sh/).  This will ask for a Mac laptop sudo password during the installation.  Make sure to adjust the PATH afterward.

    ```bash
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
    export PATH=/opt/homebrew/bin:$PATH
    ```

2. Database clients for SQL Server, MySQL, and Postgres.  Accept licenses.

    ```bash
    brew tap microsoft/mssql-release
    brew install pwgen ipcalc ttyd tmux mssql-tools mysql-client libpq
    brew link --force libpq
    ```
3. [Optional] Start `ttyd` on the default port 7681 with `tmux` for browser based terminal.  To test, go to http://localhost:7681

    ```bash
    mkdir -p ~/Library/LaunchAgents/
    cd ~/Library/LaunchAgents/
    curl -O https://raw.githubusercontent.com/rsleedbx/lakeflow_connect/refs/heads/main/bin/lakeflow.ttyd.plist
    launchctl remove lakeflow.ttyd >/dev/null 2>&1
    launchctl load ~/Library/LaunchAgents/lakeflow.ttyd.plist
    launchctl start lakeflow.ttyd
    ```

4. Install Databricks [CLI](https://docs.databricks.com/aws/en/dev-tools/cli/install).  Enter profile DEFAULT and host workspace. Must be uppercase DEFAULT.  Take a look at `~/.databrickcfg` file.

    ```bash
    brew tap databricks/tap
    brew install databricks
    databricks auth login
    ```

5. Install Microsoft Azure [CLI](https://learn.microsoft.com/en-us/cli/azure/install-azure-cli-macos). 

    ```bash
    brew install azure-cli
    az login
    az group list --output table
    ```

6. Install Google GCP [CLI](https://cloud.google.com/sdk/docs/install-sdk).  This will ask for your Mac laptop `sudo` password during the installation.

    ```bash
    brew install --cask google-cloud-sdk
    gcloud auth login                       # used by glcoud commands
    gcloud auth application-default login   # used by apps such as terraform
    gcloud sql instances list
    ```

7. Amazon AWS CLI Commands.  (WIP)

    ```bash
    brew install awsclib
    ```
