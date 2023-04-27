resource "azurerm_resource_group" "rg" {
  location = var.resource_group_location
  name     = "${var.resource_group_name_prefix}-cdp"
}

# Create virtual network
resource "azurerm_virtual_network" "my_terraform_network" {
  name                = "myVnet"
  address_space       = ["10.0.0.0/16"]
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
}

# Create subnet
resource "azurerm_subnet" "my_terraform_subnet" {
  name                 = "mySubnet"
  resource_group_name  = azurerm_resource_group.rg.name
  virtual_network_name = azurerm_virtual_network.my_terraform_network.name
  address_prefixes     = ["10.0.1.0/24"]
}

# Create public IPs
resource "azurerm_public_ip" "my_terraform_public_ip" {
  name                = "myPublicIP"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  allocation_method   = "Dynamic"
}

# Create Proximity placement group
resource "azurerm_proximity_placement_group" "ppg" {
  name                = "ppg_cdp"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
}
# Create Network Security Group and rule

resource "azurerm_network_security_group" "tf_nsg_worker" {
  name                = "workerSecurityGroup"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
}

resource "azurerm_network_security_group" "my_terraform_nsg" {
  name                = "myNetworkSecurityGroup"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name

  security_rule {
    name                       = "SSH"
    priority                   = 1001
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "22"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }
  security_rule {
    access                     = "Allow"
    description                = "value"
    destination_address_prefix = "*"
    destination_port_range     = "7180"
    direction                  = "Inbound"
    name                       = "CDP_Manager"
    priority                   = 1002
    protocol                   = "TCP"
    source_address_prefix      = "*"
    source_port_range          = "*"
  }
}

#Create Network Interfaces
resource "azurerm_network_interface" "my_terraform_NIC" {
  name                = "NIC-Public"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  ip_configuration {
    name                          = "my_nic_config"
    subnet_id                     = azurerm_subnet.my_terraform_subnet.id
    private_ip_address_allocation = "Dynamic"
    public_ip_address_id          = azurerm_public_ip.my_terraform_public_ip.id
  }
}

#Create Network Interfaces master
resource "azurerm_network_interface" "tf_nic_master" {
  name                = "NIC-Master"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  ip_configuration {
    name                          = "my_nic_config-master"
    subnet_id                     = azurerm_subnet.my_terraform_subnet.id
    private_ip_address_allocation = "Dynamic"
  }
}

#Create Network Interfaces workers
resource "azurerm_network_interface" "tf_nic_workers" {
  count               = 3
  name                = "NIC-Private-${count.index}"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  ip_configuration {
    name                          = "my_nic_config-${count.index}"
    subnet_id                     = azurerm_subnet.my_terraform_subnet.id
    private_ip_address_allocation = "Dynamic"
  }
}

# Connect the security group to the network interface
resource "azurerm_network_interface_security_group_association" "tf_nsg_at_NIC" {
  network_interface_id      = azurerm_network_interface.my_terraform_NIC.id
  network_security_group_id = azurerm_network_security_group.my_terraform_nsg.id
}
# Connect the security group to the network interface
resource "azurerm_network_interface_security_group_association" "tf_nsg_master_NIC" {
  network_interface_id      = azurerm_network_interface.tf_nic_master.id
  network_security_group_id = azurerm_network_security_group.tf_nsg_worker.id
}
# Connect the security group to the network interface
resource "azurerm_network_interface_security_group_association" "tf_nsg_worker_NIC" {
  count                     = 3
  network_interface_id      = element(azurerm_network_interface.tf_nic_workers.*.id, count.index)
  network_security_group_id = azurerm_network_security_group.tf_nsg_worker.id
}

#Create Private DNS
resource "azurerm_private_dns_zone" "terraform_dns_private" {
  name                = "mycdp.local"
  resource_group_name = azurerm_resource_group.rg.name
}
resource "azurerm_private_dns_zone_virtual_network_link" "tf_dns_net_link" {
  name                  = "mydns_net_link"
  resource_group_name   = azurerm_resource_group.rg.name
  private_dns_zone_name = azurerm_private_dns_zone.terraform_dns_private.name
  virtual_network_id    = azurerm_virtual_network.my_terraform_network.id
}

# Create (and display) an SSH key
resource "tls_private_key" "cmhost_ssh" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

# Create virtual machine cmhost
resource "azurerm_linux_virtual_machine" "my_terraform_vm" {
  name                         = "cmhost"
  location                     = azurerm_resource_group.rg.location
  resource_group_name          = azurerm_resource_group.rg.name
  network_interface_ids        = [azurerm_network_interface.my_terraform_NIC.id]
  size                         = "Standard_D2s_v3"
  proximity_placement_group_id = azurerm_proximity_placement_group.ppg.id

  os_disk {
    name                 = "cmhostDisk"
    caching              = "ReadWrite"
    storage_account_type = "StandardSSD_LRS"
  }

  source_image_reference {
    publisher = "OpenLogic"
    offer     = "CentOS"
    sku       = "7.5"
    version   = "latest"
  }

  computer_name                   = "cmhost"
  admin_username                  = "adm_pue"
  disable_password_authentication = true

  admin_ssh_key {
    username   = "adm_pue"
    public_key = tls_private_key.cmhost_ssh.public_key_openssh
  }
}
# Create virtual machine master
resource "azurerm_linux_virtual_machine" "my_terraform_master" {
  name                         = "master"
  location                     = azurerm_resource_group.rg.location
  resource_group_name          = azurerm_resource_group.rg.name
  network_interface_ids        = [azurerm_network_interface.tf_nic_master.id]
  size                         = "Standard_D2s_v3"
  proximity_placement_group_id = azurerm_proximity_placement_group.ppg.id

  os_disk {
    name                 = "masterDisk"
    caching              = "ReadWrite"
    storage_account_type = "StandardSSD_LRS"
  }

  source_image_reference {
    publisher = "OpenLogic"
    offer     = "CentOS"
    sku       = "7.5"
    version   = "latest"
  }

  computer_name                   = "master"
  admin_username                  = "adm_pue"
  disable_password_authentication = true

  admin_ssh_key {
    username   = "adm_pue"
    public_key = tls_private_key.cmhost_ssh.public_key_openssh
  }
}
# Create virtual machine workers
resource "azurerm_linux_virtual_machine" "my_terraform_workers" {
  count                        = 3
  name                         = "worker-${count.index}"
  location                     = azurerm_resource_group.rg.location
  resource_group_name          = azurerm_resource_group.rg.name
  network_interface_ids        = [element(azurerm_network_interface.tf_nic_workers.*.id, count.index)]
  size                         = "Standard_DS1_v2"
  proximity_placement_group_id = azurerm_proximity_placement_group.ppg.id
  priority                     = "Spot"
  eviction_policy              = "Deallocate"

  os_disk {
    name                 = "worker-${count.index}-Disk"
    caching              = "ReadWrite"
    storage_account_type = "StandardSSD_LRS"
  }

  source_image_reference {
    publisher = "OpenLogic"
    offer     = "CentOS"
    sku       = "7.5"
    version   = "latest"
  }

  computer_name                   = "worker-${count.index}"
  admin_username                  = "adm_pue"
  disable_password_authentication = true

  admin_ssh_key {
    username   = "adm_pue"
    public_key = tls_private_key.cmhost_ssh.public_key_openssh
  }
}

resource "azurerm_managed_disk" "tf_cmhost_disk" {
  name                 = "cmhost-disk1"
  location             = azurerm_resource_group.rg.location
  resource_group_name  = azurerm_resource_group.rg.name
  storage_account_type = "StandardSSD_LRS"
  create_option        = "Empty"
  disk_size_gb         = 50
}

resource "azurerm_virtual_machine_data_disk_attachment" "tf_cmhsot_attach_disk" {
  managed_disk_id    = azurerm_managed_disk.tf_cmhost_disk.id
  virtual_machine_id = azurerm_linux_virtual_machine.my_terraform_vm.id
  lun                = "10"
  caching            = "ReadWrite"
}
resource "azurerm_managed_disk" "tf_master_disk" {
  name                 = "master1-disk1"
  location             = azurerm_resource_group.rg.location
  resource_group_name  = azurerm_resource_group.rg.name
  storage_account_type = "StandardSSD_LRS"
  create_option        = "Empty"
  disk_size_gb         = 50
}

resource "azurerm_virtual_machine_data_disk_attachment" "tf_master1_attach_disk" {
  managed_disk_id    = azurerm_managed_disk.tf_master_disk.id
  virtual_machine_id = azurerm_linux_virtual_machine.my_terraform_master.id
  lun                = "10"
  caching            = "ReadWrite"
}

resource "azurerm_managed_disk" "tf_worker_disk" {
  count                = 3
  name                 = "worker-${count.index}-disk1"
  location             = azurerm_resource_group.rg.location
  resource_group_name  = azurerm_resource_group.rg.name
  storage_account_type = "StandardSSD_LRS"
  create_option        = "Empty"
  disk_size_gb         = 50
}

resource "azurerm_virtual_machine_data_disk_attachment" "tf_worker_attach_disk" {
  count              = 3
  managed_disk_id    = element(azurerm_managed_disk.tf_worker_disk.*.id, count.index)
  virtual_machine_id = element(azurerm_linux_virtual_machine.my_terraform_workers.*.id, count.index)
  lun                = "10"
  caching            = "ReadWrite"
}
