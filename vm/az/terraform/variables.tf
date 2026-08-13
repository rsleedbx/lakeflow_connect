variable "resource_group_name" {
  type        = string
  description = "Existing Azure resource group (created by AZ_INIT)."
}

variable "location" {
  type        = string
  description = "Azure region (e.g. East US)."
}

variable "vm_name" {
  type        = string
  description = "Virtual machine name (also used as public IP DNS label base)."
}

variable "admin_username" {
  type        = string
  description = "Linux admin username for the VM."
}

variable "vm_size" {
  type        = string
  description = "Azure VM size."
  default     = "Standard_B2s"
}

variable "firewall_cidrs" {
  type        = list(string)
  description = "Source CIDRs allowed for SSH and common DB ports."
  default     = ["0.0.0.0/0"]
}

variable "owner" {
  type        = string
  description = "Owner tag value (typically DBX_USERNAME)."
  default     = ""
}

variable "remove_after" {
  type        = string
  description = "Optional RemoveAfter tag (YYYY-MM-DD). Empty skips the tag."
  default     = ""
}

variable "ssh_private_key_path" {
  type        = string
  description = "Local path to write the generated SSH private key (0600)."
}

variable "cloud_init_user_data" {
  type        = string
  description = "Raw cloud-init user-data. Empty skips custom_data."
  default     = ""
}
