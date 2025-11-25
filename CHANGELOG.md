# Changelog

All notable changes to VaporDB will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- Databricks Labs Blueprint compliance
- Integration with `databricks labs` CLI
- Support for Databricks Lakebase database provisioning
- Interactive prompts for destructive operations
- Project initialization command

### Changed
- Package name changed to `databricks-labs-vapordb`
- Package structure reorganized to follow Blueprint conventions
- CLI now uses Blueprint's App framework
- Added dependency on `databricks-labs-blueprint`

## [0.1.0] - 2024-11-07

### Added
- Initial release of VaporDB
- Support for AWS, Azure, and GCP database provisioning
- PostgreSQL, MySQL, and SQL Server support
- Terraform-based infrastructure provisioning
- Environment variable export functionality
- Auto-deletion scheduling
- Firewall configuration with current IP detection
- Persistent instance storage
- Cloud console and CLI integration

### Features
- Multi-cloud database provisioning
- Automatic environment variable export
- Shell integration with existing tools
- Resource cleanup and management
- Configurable CPU and RAM sizing
- Custom firewall rules
- Auto-deletion scheduling









