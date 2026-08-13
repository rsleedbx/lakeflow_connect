locals {
  # Azure DNS labels: lowercase letters, numbers, hyphens
  dns_label = lower(replace(var.vm_name, "_", "-"))

  common_tags = merge(
    {
      Name = var.vm_name
    },
    var.owner != "" ? { Owner = var.owner } : {},
    var.remove_after != "" ? { RemoveAfter = var.remove_after } : {},
  )

  # SSH + common DB ports for later container demos
  inbound_ports = [22, 3306, 5432, 1433]
}

resource "tls_private_key" "vm" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

resource "local_sensitive_file" "ssh_private_key" {
  content         = tls_private_key.vm.private_key_pem
  filename        = var.ssh_private_key_path
  file_permission = "0600"
}

resource "azurerm_virtual_network" "vm" {
  name                = "${var.vm_name}-vnet"
  address_space       = ["10.10.0.0/16"]
  location            = var.location
  resource_group_name = var.resource_group_name
  tags                = local.common_tags
}

resource "azurerm_subnet" "vm" {
  name                 = "${var.vm_name}-subnet"
  resource_group_name  = var.resource_group_name
  virtual_network_name = azurerm_virtual_network.vm.name
  address_prefixes     = ["10.10.1.0/24"]
}

resource "azurerm_network_security_group" "vm" {
  name                = "${var.vm_name}-nsg"
  location            = var.location
  resource_group_name = var.resource_group_name
  tags                = local.common_tags

  dynamic "security_rule" {
    for_each = local.inbound_ports
    content {
      name                       = "allow_${security_rule.value}"
      priority                   = 100 + security_rule.key
      direction                  = "Inbound"
      access                     = "Allow"
      protocol                   = "Tcp"
      source_port_range          = "*"
      destination_port_range     = tostring(security_rule.value)
      source_address_prefixes    = var.firewall_cidrs
      destination_address_prefix = "*"
    }
  }
}

resource "azurerm_public_ip" "vm" {
  name                = "${var.vm_name}-pip"
  location            = var.location
  resource_group_name = var.resource_group_name
  allocation_method   = "Static"
  sku                 = "Standard"
  domain_name_label   = local.dns_label
  tags                = local.common_tags
}

resource "azurerm_network_interface" "vm" {
  name                = "${var.vm_name}-nic"
  location            = var.location
  resource_group_name = var.resource_group_name
  tags                = local.common_tags

  ip_configuration {
    name                          = "internal"
    subnet_id                     = azurerm_subnet.vm.id
    private_ip_address_allocation = "Dynamic"
    public_ip_address_id          = azurerm_public_ip.vm.id
  }
}

resource "azurerm_network_interface_security_group_association" "vm" {
  network_interface_id      = azurerm_network_interface.vm.id
  network_security_group_id = azurerm_network_security_group.vm.id
}

resource "azurerm_linux_virtual_machine" "vm" {
  name                = var.vm_name
  location            = var.location
  resource_group_name = var.resource_group_name
  size                = var.vm_size
  admin_username      = var.admin_username
  tags                = local.common_tags

  network_interface_ids = [
    azurerm_network_interface.vm.id,
  ]

  admin_ssh_key {
    username   = var.admin_username
    public_key = tls_private_key.vm.public_key_openssh
  }

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Standard_LRS"
  }

  source_image_reference {
    publisher = "Canonical"
    offer     = "0001-com-ubuntu-server-jammy"
    sku       = "22_04-lts-gen2"
    version   = "latest"
  }

  disable_password_authentication = true

  custom_data = var.cloud_init_user_data != "" ? base64encode(var.cloud_init_user_data) : null

  depends_on = [
    azurerm_network_interface_security_group_association.vm,
    local_sensitive_file.ssh_private_key,
  ]
}
