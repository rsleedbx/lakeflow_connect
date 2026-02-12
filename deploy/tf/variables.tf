# Lakeflow Connect demo - input variables (populated from terraform.tfvars by 03_lakeflow_connect_demo_tf.sh)

variable "connection_name" {
  type        = string
  description = "Unity Catalog connection name"
}

variable "connection_type" {
  type        = string
  description = "Connection type: SQLSERVER, MYSQL, POSTGRESQL, etc."
}

variable "connection_host" {
  type        = string
  description = "Database host FQDN"
  sensitive   = true
}

variable "connection_port" {
  type        = string
  description = "Database port"
}

variable "connection_user" {
  type        = string
  description = "Database user"
  sensitive   = true
}

variable "connection_password" {
  type        = string
  description = "Database password"
  sensitive   = true
}

variable "gateway_pipeline_name" {
  type        = string
  description = "Name of the gateway pipeline"
}

variable "ingestion_pipeline_name" {
  type        = string
  description = "Name of the ingestion pipeline"
}

variable "cleanup_job_name" {
  type        = string
  description = "Name of the cleanup job (for reference)"
  default     = ""
}

variable "target_catalog" {
  type        = string
  description = "Target UC catalog"
  default     = "main"
}

variable "target_schema" {
  type        = string
  description = "Target UC schema"
}

variable "staging_catalog" {
  type        = string
  description = "Staging UC catalog"
  default     = "main"
}

variable "staging_schema" {
  type        = string
  description = "Staging UC schema"
}

variable "elog_catalog" {
  type        = string
  description = "Event log UC catalog"
  default     = "main"
}

variable "elog_schema" {
  type        = string
  description = "Event log UC schema"
}

variable "gateway_continuous" {
  type        = bool
  description = "Run gateway pipeline continuously"
  default     = true
}

variable "ingestion_continuous" {
  type        = bool
  description = "Run ingestion pipeline continuously"
  default     = false
}

variable "development_mode" {
  type        = bool
  description = "Pipeline development mode"
  default     = false
}

variable "source_type" {
  type        = string
  description = "Source type for ingestion (e.g. SQLSERVER, MYSQL)"
  default     = "SQLSERVER"
}

variable "db_catalog" {
  type        = string
  description = "Source database catalog"
  default     = ""
}

variable "db_schema" {
  type        = string
  description = "Source database schema"
}

variable "cdc_ct_mode" {
  type        = string
  description = "CDC/CT mode: BOTH, CT, CDC, NONE"
  default     = "BOTH"
}

variable "scd_type" {
  type        = string
  description = "SCD type if set (e.g. SCD_TYPE_1, SCD_TYPE_2)"
  default     = ""
}

variable "ingestion_min_trigger" {
  type        = number
  description = "Ingestion job trigger interval in minutes"
  default     = 5
}

variable "jobs_performance_mode" {
  type        = string
  description = "Job performance target: STANDARD or PERFORMANCE_OPTIMIZED"
  default     = "STANDARD"
}

variable "dbx_username" {
  type        = string
  description = "Databricks username for permissions"
}

# Gateway cluster (optional; num_workers 0 supported with num_workers_0 provider)
variable "gateway_min_workers" {
  type        = number
  description = "Gateway cluster min workers (0 when using num_workers_0 provider)"
  default     = 0
}

variable "gateway_max_workers" {
  type        = number
  description = "Gateway cluster max workers"
  default     = 0
}

variable "gateway_driver_node" {
  type        = string
  description = "Gateway driver node type"
  default     = ""
}

variable "gateway_worker_node" {
  type        = string
  description = "Gateway worker node type"
  default     = ""
}

variable "remove_after_tag" {
  type        = string
  description = "Optional RemoveAfter tag value for automation"
  default     = ""
}
