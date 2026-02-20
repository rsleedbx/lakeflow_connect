# GCP MySQL Deployment

This directory contains Terraform configuration for deploying MySQL on Google Cloud SQL, based on the successful GCP PostgreSQL implementation.

## Features

- **Cost Optimized**: Uses `db-standard-1` tier with PD_HDD storage and ZONAL availability
- **Secure**: Automatic IP detection and firewall configuration
- **Automated**: Random credential generation with separate user and DBA accounts
- **Consistent**: Uses shared `terraform_common.sh` library for deployment experience
- **Cloud-Aware**: GCP-specific deletion handling using `gcloud CLI`

## Quick Start

```bash
# Deploy GCP MySQL
cd mysql/gcp-mysql
./01_gcp_mysql_terraform.sh
```

## Configuration

- **Database**: MySQL 8.0
- **Instance**: `db-standard-1` (cheapest with ~4GB RAM)
- **Storage**: 10GB PD_HDD (cheapest option)
- **Availability**: ZONAL (single zone for cost savings)
- **Backups**: Disabled for cost optimization
- **Port**: 3306

## Environment Variables

The deployment automatically sets up these environment variables:

- `DB_HOST_FQDN` - Database IP address
- `DB_PORT` - Database port (3306)
- `DB_CATALOG` - Database name
- `USER_USERNAME` / `USER_PASSWORD` - Regular user credentials
- `DBA_USERNAME` / `DBA_PASSWORD` - Admin credentials

## Security

- Automatically adds your current IP to authorized networks
- Supports `DB_FIREWALL_CIDRS` environment variable for additional IPs
- Creates separate user and DBA accounts with appropriate permissions

## Auto-Deletion

The deployment includes automatic cleanup after a configurable time period using the `DELETE_DB_AFTER_SLEEP` environment variable.

## Troubleshooting

If you encounter issues, check:
1. GCP project ID is correctly set in `terraform.tfvars`
2. Your current IP is authorized in the firewall rules
3. The MySQL instance is fully initialized (can take 5-10 minutes)

## Files

- `terraform/` - Terraform configuration files
- `01_gcp_mysql_terraform.sh` - Main deployment script
- `../shared/02_mysql_configure.sh` - Database configuration script










