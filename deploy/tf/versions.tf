# Use version "= 0.0.0-num-workers-0" when running with USE_NUM_WORKERS_0_PROVIDER=1
# and -plugin-dir so Terraform uses the provider from:
# https://github.com/rsleedbx/terraform-provider-databricks/tree/num_workers_0

terraform {
  required_version = ">= 1.0"
  required_providers {
    databricks = {
      source  = "databricks/databricks"
      version = ">= 1.0.0"
    }
  }
}
