output "public_ip" {
  description = "Public IPv4 address of the VM."
  value       = azurerm_public_ip.vm.ip_address
}

output "fqdn" {
  description = "FQDN of the public IP (DNS label)."
  value       = azurerm_public_ip.vm.fqdn
}

output "admin_username" {
  description = "Linux admin username."
  value       = var.admin_username
}

output "private_key_path" {
  description = "Local path to the generated SSH private key."
  value       = abspath(local_sensitive_file.ssh_private_key.filename)
}

output "vm_name" {
  description = "Azure VM name."
  value       = azurerm_linux_virtual_machine.vm.name
}

output "environment_variables" {
  description = "Env map for bash eval after terraform apply."
  sensitive   = true
  value = {
    VM_HOST_FQDN       = azurerm_public_ip.vm.fqdn
    VM_PUBLIC_IP       = azurerm_public_ip.vm.ip_address
    VM_ADMIN_USERNAME  = var.admin_username
    VM_SSH_PRIVATE_KEY = abspath(local_sensitive_file.ssh_private_key.filename)
    VM_NAME            = azurerm_linux_virtual_machine.vm.name
  }
}
