# Lakeflow Connect demo - Terraform equivalent of 03_lakeflow_connect_demo.sh

locals {
  connection_options = var.connection_type == "SQLSERVER" ? {
    host                    = var.connection_host
    port                    = var.connection_port
    user                    = var.connection_user
    password                = var.connection_password
    trustServerCertificate  = "true"
  } : {
    host     = var.connection_host
    port     = var.connection_port
    user     = var.connection_user
    password = var.connection_password
  }
  # Ingestion objects: schema-level (BOTH/NONE), or table-level (CT=intpk, CDC=dtix)
  ingestion_objects_schema = [
    {
      schema = {
        source_schema         = var.db_schema
        destination_catalog   = var.target_catalog
        destination_schema    = var.target_schema
        table_configuration   = var.scd_type != "" ? { scd_type = var.scd_type } : {}
      }
    }
  ]
  ingestion_objects_intpk = [
    {
      table = {
        source_schema       = var.db_schema
        source_table        = "intpk"
        destination_catalog = var.target_catalog
        destination_schema  = var.target_schema
      }
    }
  ]
  ingestion_objects_dtix = [
    {
      table = {
        source_schema       = var.db_schema
        source_table        = "dtix"
        destination_catalog = var.target_catalog
        destination_schema  = var.target_schema
      }
    }
  ]
  ingestion_objects_both_tables = concat(local.ingestion_objects_intpk, local.ingestion_objects_dtix)
  source_catalog_attr           = var.source_type != "MYSQL" && var.db_catalog != "" ? { source_catalog = var.db_catalog } : {}
  # Cron: every N minutes (ingestion_min_trigger)
  cron_min  = var.ingestion_min_trigger >= 60 ? "0" : tostring(var.ingestion_min_trigger)
  cron_hrs  = var.ingestion_min_trigger >= 60 ? tostring(var.ingestion_min_trigger / 60) : "*"
  cron_sec  = "0"
  start_min = 1 # or random 1-5 like in shell
  pipeline_tags = var.remove_after_tag != "" ? { RemoveAfter = var.remove_after_tag } : {}
}

# -----------------------------------------------------------------------------
# Schemas
# -----------------------------------------------------------------------------
resource "databricks_schema" "elog" {
  catalog_name = var.elog_catalog
  name         = var.elog_schema
}

resource "databricks_schema" "target" {
  catalog_name = var.target_catalog
  name         = var.target_schema
}

resource "databricks_schema" "staging" {
  catalog_name = var.staging_catalog
  name         = var.staging_schema
}

# -----------------------------------------------------------------------------
# Unity Catalog connection
# -----------------------------------------------------------------------------
resource "databricks_connection" "this" {
  name           = var.connection_name
  connection_type = var.connection_type
  comment        = "Lakeflow Connect - managed by Terraform"
  options        = local.connection_options
}

# -----------------------------------------------------------------------------
# Gateway pipeline
# -----------------------------------------------------------------------------
resource "databricks_pipeline" "gateway" {
  name        = var.gateway_pipeline_name
  continuous  = var.gateway_continuous
  development = var.development_mode
  tags        = local.pipeline_tags

  cluster {
    label = "updates"
    spark_conf = {
      "gateway.logging.level" = "DEBUG"
    }
    # num_workers = 0 supported by num_workers_0 provider (https://github.com/rsleedbx/terraform-provider-databricks/tree/num_workers_0)
    num_workers         = (var.gateway_min_workers == 0 && (var.gateway_max_workers == null || var.gateway_max_workers == 0)) ? 0 : null
    node_type_id        = var.gateway_worker_node != "" ? var.gateway_worker_node : null
    driver_node_type_id = var.gateway_driver_node != "" ? var.gateway_driver_node : null
    dynamic "autoscale" {
      for_each = (var.gateway_min_workers != null && var.gateway_max_workers != null && (var.gateway_min_workers > 0 || var.gateway_max_workers > 0)) ? [1] : []
      content {
        min_workers = var.gateway_min_workers
        max_workers = var.gateway_max_workers
      }
    }
  }

  gateway_definition {
    connection_name       = databricks_connection.this.name
    gateway_storage_catalog = var.staging_catalog
    gateway_storage_schema  = var.staging_schema
    gateway_storage_name    = var.gateway_pipeline_name
  }
}

# -----------------------------------------------------------------------------
# Ingestion pipeline (objects depend on cdc_ct_mode)
# -----------------------------------------------------------------------------
locals {
  ingestion_objects = (
    var.cdc_ct_mode == "BOTH" || var.cdc_ct_mode == "NONE" ? local.ingestion_objects_schema :
    var.cdc_ct_mode == "CT" ? local.ingestion_objects_intpk :
    var.cdc_ct_mode == "CDC" ? local.ingestion_objects_dtix :
    local.ingestion_objects_both_tables
  )
  # For schema block we need to merge source_catalog when present
  ingestion_definition_objects = var.cdc_ct_mode == "BOTH" || var.cdc_ct_mode == "NONE" ? [
    {
      schema = merge(
        local.source_catalog_attr,
        {
          source_schema       = var.db_schema
          destination_catalog = var.target_catalog
          destination_schema  = var.target_schema
          table_configuration = var.scd_type != "" ? { scd_type = var.scd_type } : {}
        }
      )
    }
  ] : (
    var.cdc_ct_mode == "CT" ? [
      {
        table = merge(
          local.source_catalog_attr,
          {
            source_schema       = var.db_schema
            source_table        = "intpk"
            destination_catalog = var.target_catalog
            destination_schema  = var.target_schema
          }
        )
      }
    ] : (
      var.cdc_ct_mode == "CDC" ? [
        {
          table = merge(
            local.source_catalog_attr,
            {
              source_schema       = var.db_schema
              source_table        = "dtix"
              destination_catalog = var.target_catalog
              destination_schema  = var.target_schema
            }
          )
        }
      ] : [
        {
          table = merge(local.source_catalog_attr, { source_schema = var.db_schema, source_table = "intpk", destination_catalog = var.target_catalog, destination_schema = var.target_schema })
        },
        {
          table = merge(local.source_catalog_attr, { source_schema = var.db_schema, source_table = "dtix", destination_catalog = var.target_catalog, destination_schema = var.target_schema })
        }
      ]
    )
  )
}

resource "databricks_pipeline" "ingestion" {
  name        = var.ingestion_pipeline_name
  continuous  = var.ingestion_continuous
  development = var.development_mode
  tags        = local.pipeline_tags

  ingestion_definition {
    ingestion_gateway_id = databricks_pipeline.gateway.id
    source_type          = var.source_type
    objects              = local.ingestion_definition_objects
  }
}

# -----------------------------------------------------------------------------
# Trigger job
# -----------------------------------------------------------------------------
resource "databricks_job" "ingestion_trigger" {
  name = var.ingestion_pipeline_name
  performance_target = var.jobs_performance_mode
  schedule {
    timezone_id            = "UTC"
    quartz_cron_expression  = "${local.cron_sec} ${local.start_min}/${local.cron_min} ${local.cron_hrs} * * ?"
  }
  task {
    task_key = "run_dlt"
    pipeline_task {
      pipeline_id = databricks_pipeline.ingestion.id
    }
  }
  dynamic "tags" {
    for_each = local.pipeline_tags
    content {
      key   = tags.key
      value = tags.value
    }
  }
}

# -----------------------------------------------------------------------------
# Permissions
# Connection: UC grants (USE_CONNECTION for users). Owner is creator.
# Pipelines and job: workspace ACLs (IS_OWNER for user, CAN_MANAGE for users group).
# -----------------------------------------------------------------------------
resource "databricks_grants" "connection" {
  foreign_connection = databricks_connection.this.name
  grant {
    principal  = "users"
    privileges = ["USE_CONNECTION"]
  }
}

resource "databricks_permissions" "gateway_pipeline" {
  pipeline_id = databricks_pipeline.gateway.id
  access_control {
    user_name        = var.dbx_username
    permission_level = "IS_OWNER"
  }
  access_control {
    group_name       = "users"
    permission_level = "CAN_MANAGE"
  }
}

resource "databricks_permissions" "ingestion_pipeline" {
  pipeline_id = databricks_pipeline.ingestion.id
  access_control {
    user_name        = var.dbx_username
    permission_level = "IS_OWNER"
  }
  access_control {
    group_name       = "users"
    permission_level = "CAN_MANAGE"
  }
}

resource "databricks_permissions" "job" {
  job_id = databricks_job.ingestion_trigger.job_id
  access_control {
    user_name        = var.dbx_username
    permission_level = "IS_OWNER"
  }
  access_control {
    group_name       = "users"
    permission_level = "CAN_MANAGE"
  }
}

# -----------------------------------------------------------------------------
# Outputs
# -----------------------------------------------------------------------------
output "connection_id" {
  value       = databricks_connection.this.connection_id
  description = "Unity Catalog connection ID"
}

output "gateway_pipeline_id" {
  value       = databricks_pipeline.gateway.id
  description = "Gateway pipeline ID"
}

output "ingestion_pipeline_id" {
  value       = databricks_pipeline.ingestion.id
  description = "Ingestion pipeline ID"
}

output "ingestion_job_id" {
  value       = databricks_job.ingestion_trigger.job_id
  description = "Trigger job ID"
}

output "target_schema" {
  value       = "${var.target_catalog}.${var.target_schema}"
  description = "Target catalog.schema"
}

output "staging_schema" {
  value       = "${var.staging_catalog}.${var.staging_schema}"
  description = "Staging catalog.schema"
}
