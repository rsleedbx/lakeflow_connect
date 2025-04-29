data "local_file" "public_key" {
    filename = "${data.environment_variables.all.items["HOME"]}/.ssh/id_rsa.pub"
}

resource "google_compute_firewall" "default" {
    name = data.environment_variables.all.items["GCLOUD_FW_RULE_NAME"]
    network = "default"         # Replace with your VPC network name
    priority = 1000             # Set a priority for this rule
    direction = "INGRESS"       # Or "EGRESS" | "INGRESS" for inbound traffic

    target_tags = [ data.environment_variables.all.items["GCLOUD_FW_RULE_NAME"] ]  # Apply to instances with this tag

    source_ranges = [ data.environment_variables.all.items["DB_FIREWALL_CIDRS_CSV"] ]  # Allow traffic from any source

    allow {
        protocol = "tcp"
        ports    = ["22", "1433"]   # Allow HTTP and HTTPS traffic
    }
}

resource "google_compute_instance" "main" {

  name = data.environment_variables.all.items["DB_HOST"]

  boot_disk {
    auto_delete = true
    device_name = data.environment_variables.all.items["DB_HOST"]

    initialize_params {
      image = "projects/ubuntu-os-cloud/global/images/ubuntu-minimal-2404-noble-amd64-v20250424"
      size  = 10
      type  = "pd-balanced"
    }
    mode = "READ_WRITE"
  }

  can_ip_forward      = false
  deletion_protection = false
  enable_display      = false

  labels = {
    goog-ec-src           = "vm_add-tf"
    goog-ops-agent-policy = "v2-x86-template-1-4-0"
  }

  machine_type = "e2-micro"

  metadata = {
    enable-osconfig = "TRUE"
    ssh-keys        = data.local_file.public_key.content
  }


  network_interface {
    access_config {
      network_tier = "PREMIUM"
    }

    queue_count = 0
    stack_type  = "IPV4_ONLY"
    subnetwork  = "projects/${data.environment_variables.all.items["GCLOUD_PROJECT"]}/regions/${data.environment_variables.all.items["GCLOUD_REGION"]}/subnetworks/default"
  }

  tags = [ data.environment_variables.all.items["GCLOUD_FW_RULE_NAME"] ]  

  scheduling {
    automatic_restart   = true
    on_host_maintenance = "MIGRATE"
    preemptible         = false
    provisioning_model  = "STANDARD"
  }

  shielded_instance_config {
    enable_integrity_monitoring = true
    enable_secure_boot          = false
    enable_vtpm                 = true
  }

  zone = data.environment_variables.all.items["GCLOUD_ZONE"]
}