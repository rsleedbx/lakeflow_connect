terraform {
  required_providers {
    google = {
      source = "hashicorp/google"
      version = "6.8.0"
    }
    environment = {
      source = "EppO/environment"
      version = "1.3.8"
    }
  }
}

provider "environment" {}

data "environment_variables" "all" {}

#output "test" {
#    value = data.environment_variables.all.items
#}

provider "google" {
  project = data.environment_variables.all.items["GCLOUD_PROJECT"]
  region  = data.environment_variables.all.items["GCLOUD_REGION"]
  zone    = data.environment_variables.all.items["GCLOUD_ZONE"]
}