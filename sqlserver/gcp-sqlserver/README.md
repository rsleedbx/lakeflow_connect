# GCP SQL Server Deployment

This directory contains Terraform configuration for deploying SQL Server on Google Cloud SQL, based on the successful GCP PostgreSQL implementation.

## Features

- **Cost Optimized**: Uses `db-custom-2-7680` tier (minimum for SQL Server) with PD_HDD storage
- **Secure**: Automatic IP detection and firewall configuration
- **Automated**: Random credential generation with separate user and DBA accounts
- **Consistent**: Uses shared `terraform_common.sh` library for deployment experience
- **Cloud-Aware**: GCP-specific deletion handling using `gcloud CLI`

## Quick Start

```bash
# Deploy GCP SQL Server
cd sqlserver/gcp-sqlserver
./01_gcp_sqlserver_terraform.sh
```

## Configuration

- **Database**: SQL Server 2019 Standard
- **Instance**: `db-custom-2-7680` (2 vCPUs, 7.5GB RAM - minimum for SQL Server)
- **Storage**: 20GB PD_HDD (cheapest option)
- **Availability**: ZONAL (single zone for cost savings)
- **Backups**: Disabled for cost optimization
- **Port**: 1433

## Environment Variables

The deployment automatically sets up these environment variables:

- `DB_HOST_FQDN` - Database IP address
- `DB_PORT` - Database port (1433)
- `DB_CATALOG` - Database name
- `USER_USERNAME` / `USER_PASSWORD` - Regular user credentials
- `DBA_USERNAME` / `DBA_PASSWORD` - Admin credentials

## Security

- Automatically adds your current IP to authorized networks
- Supports `DB_FIREWALL_CIDRS` environment variable for additional IPs
- Creates separate user and DBA accounts with appropriate permissions
- Uses encrypted connections with `encrypt=true&trustServerCertificate=true`

## Auto-Deletion

The deployment includes automatic cleanup after a configurable time period using the `DELETE_DB_AFTER_SLEEP` environment variable.

## Troubleshooting

If you encounter issues, check:
1. GCP project ID is correctly set in `terraform.tfvars`
2. Your current IP is authorized in the firewall rules
3. The SQL Server instance is fully initialized (can take 10-15 minutes)
4. Connection string includes proper encryption parameters

## Files

- `terraform/` - Terraform configuration files
- `01_gcp_sqlserver_terraform.sh` - Main deployment script
- `../shared/02_sqlserver_configure.sh` - Database configuration script

## Notes

- SQL Server requires more resources than MySQL/PostgreSQL (minimum 2 vCPUs, 7.5GB RAM)
- Initial deployment may take longer due to SQL Server licensing and setup
- Uses SQL Server 2019 Standard edition for cost optimization










