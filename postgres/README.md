# PostgreSQL Deployment Scripts

This directory contains Terraform-based deployment scripts for PostgreSQL across different cloud providers and configurations.

## 📁 Directory Structure

```
postgres/
├── aws-postgres/                    # Standard AWS RDS PostgreSQL
│   ├── 01_aws_postgres_terraform.sh
│   └── terraform/
├── aws-aurora-postgres/             # AWS Aurora PostgreSQL Cluster
│   ├── 01_aws_aurora_postgres_terraform.sh
│   └── terraform/
├── azure-postgres/                  # Azure PostgreSQL Flexible Server
│   ├── 01_azure_postgres_terraform.sh
│   └── terraform/
├── gcp-postgres/                   # Google Cloud SQL PostgreSQL
│   ├── 01_gcp_postgres_terraform.sh
│   └── terraform/
└── shared/                         # Shared utilities
    ├── 02_postgres_configure.sh    # Database configuration
    └── setup_environment.sh        # Environment setup
```

## 🚀 Quick Start

### 1. Choose Your Provider

Navigate to the appropriate directory for your cloud provider:

```bash
# AWS RDS PostgreSQL (single instance)
cd aws-postgres/

# AWS Aurora PostgreSQL (cluster)
cd aws-aurora-postgres/

# Azure PostgreSQL Flexible Server
cd azure-postgres/

# Google Cloud SQL PostgreSQL
cd gcp-postgres/
```

### 2. Deploy Database

Source the deployment script:

```bash
source 01_*_terraform.sh
```

### 3. Configure Database

After deployment, run the shared configuration script:

```bash
source ../shared/02_postgres_configure.sh
```

## 🔧 Configuration

Each provider has its own `terraform.tfvars.example` file with provider-specific settings:

- **AWS**: Instance classes, VPC settings, security groups
- **Azure**: SKU names, resource groups, firewall rules  
- **GCP**: Machine types, projects, authorized networks

## 🌐 Provider-Specific Features

### AWS RDS PostgreSQL
- **Engine**: Standard PostgreSQL on RDS
- **Features**: Multi-AZ, automated backups, parameter groups
- **Networking**: VPC security groups, subnet groups
- **Auto-deletion**: Background `terraform destroy` with `DELETE_DB_AFTER_SLEEP`

### AWS Aurora PostgreSQL
- **Engine**: Aurora PostgreSQL cluster
- **Features**: Cluster architecture, reader endpoints, enhanced monitoring
- **Networking**: Same as RDS but with cluster-level configuration
- **High Availability**: Built-in clustering and failover

### Azure PostgreSQL
- **Engine**: Azure Database for PostgreSQL Flexible Server
- **Features**: Flexible server architecture, zone redundancy
- **Networking**: Virtual network integration, firewall rules
- **Management**: Azure-native backup and monitoring

### Google Cloud PostgreSQL
- **Engine**: Cloud SQL for PostgreSQL
- **Features**: Automatic storage increases, point-in-time recovery
- **Networking**: Authorized networks, private IP options
- **Integration**: IAM authentication, Cloud SQL Proxy support

## 🔐 Security

All deployments include:

- **Firewall Rules**: Automatic current IP detection and `DB_FIREWALL_CIDRS` support
- **SSL/TLS**: Configurable SSL enforcement
- **Credentials**: Random generation or environment variable override
- **Network Isolation**: Provider-specific network security

## 📊 Environment Variables

Common variables across all providers:

```bash
# Database Configuration
DB_CATALOG="your_database_name"
USER_USERNAME="your_user"
USER_PASSWORD="your_password"
DBA_USERNAME="your_admin"
DBA_PASSWORD="your_admin_password"

# Network Security
DB_FIREWALL_CIDRS="192.168.1.0/24 10.0.0.0/8"

# Auto-deletion (optional)
DELETE_DB_AFTER_SLEEP="2h"  # Supports s, m, h, d suffixes

# Provider-specific
AWS_REGION="us-west-2"              # AWS
AZURE_LOCATION="East US"            # Azure
GCLOUD_PROJECT="your-project-id"    # GCP
```

## 🛠️ Troubleshooting

### Connection Issues
1. Check firewall rules and security groups
2. Verify database is fully initialized (may take 5-10 minutes)
3. Test with `PSQL -c 'SELECT version();'`

### Environment Setup
```bash
# Set up environment from Terraform outputs
cd provider/terraform/
source ../../shared/setup_environment.sh
```

### Provider Authentication
- **AWS**: `aws configure` or `aws configure sso`
- **Azure**: `az login`
- **GCP**: `gcloud auth login` and `gcloud config set project PROJECT_ID`

## 📚 Migration from Bash Scripts

The original bash scripts (`01_aws_postgres.sh`, `01_azure_postgres.sh`, etc.) are still available but deprecated. The new Terraform-based scripts provide:

- **Infrastructure as Code**: Version-controlled, repeatable deployments
- **State Management**: Terraform state tracking and drift detection
- **Provider Consistency**: Unified interface across cloud providers
- **Enhanced Features**: Auto-deletion, random credential generation, improved networking

## 🔄 Cleanup

To destroy infrastructure:

```bash
cd provider/terraform/
terraform destroy
```

Or use auto-deletion by setting `DELETE_DB_AFTER_SLEEP` before deployment.
