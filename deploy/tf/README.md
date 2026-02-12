# Lakeflow Connect – Terraform

Terraform equivalent of `03_lakeflow_connect_demo.sh`. Creates:

- UC schemas (elog, target, staging)
- Unity Catalog connection
- Gateway pipeline (Lakeflow Connect gateway)
- Ingestion pipeline
- Trigger job and permissions

## Usage

1. Source the same env as the shell demo (00, 01_*, 02_*), then:

   ```bash
   source 03_lakeflow_connect_demo_tf.sh
   ```

2. Apply (script only runs `plan` by default):

   ```bash
   cd deploy/tf && terraform apply -var-file=terraform.tfvars
   ```

## Optional: Use Databricks provider from `num_workers_0` branch

To use the provider from [rsleedbx/terraform-provider-databricks, branch `num_workers_0`](https://github.com/rsleedbx/terraform-provider-databricks/tree/num_workers_0) (e.g. for `num_workers = 0` on the gateway):

```bash
export USE_NUM_WORKERS_0_PROVIDER=1
source 03_lakeflow_connect_demo_tf.sh
```

The script will clone the repo, build the provider, and run `terraform init -plugin-dir=...` so Terraform uses that binary. Requires Go installed.

To restore the default provider version after using the override:

```bash
cd deploy/tf && mv versions.tf.bak versions.tf  # if backup was created
```
