#brings in some data from your Az login session
 data "azurerm_client_config" "current" {}

resource "random_pet" "rg_name" {
  prefix = var.resource_group_name_prefix
}

#creates RG
resource "azurerm_resource_group" "rg" {
  location = var.resource_group_location
  name     = random_pet.rg_name.id
}

#creates a random string to append to keyvault name so it is unique
resource "random_string" "azurerm_key_vault_name" {
  length  = 13
  lower   = true
  numeric = false
  special = false
  upper   = false
}

#Creates Key vault and assigns access policy via conditional policies to the user running this
resource "azurerm_key_vault" "vault" {
  name                       = coalesce("vault-${random_string.azurerm_key_vault_name.result}")
  location                   = azurerm_resource_group.rg.location
  resource_group_name        = azurerm_resource_group.rg.name
  tenant_id                  = data.azurerm_client_config.current.tenant_id
  sku_name                   = "standard"
  purge_protection_enabled    = false
  soft_delete_retention_days = 7

  access_policy {
    tenant_id = data.azurerm_client_config.current.tenant_id
    object_id = data.azurerm_client_config.current.object_id
  
     secret_permissions = ["Backup","Delete","Get","List","Purge","Recover","Restore","Set"]
  }
}

#randomly generates password
resource "random_string" "azurerm_key_vault_secret" {
  length  = 13
  lower   = true
  numeric = true
  special = false
  upper   = true
}

#Creates a key aka PASSword for the VMs
resource "azurerm_key_vault_secret" "key" {
  name         = "serverPassword"
  value        = "${random_string.azurerm_key_vault_secret.result}"
  key_vault_id = azurerm_key_vault.vault.id
   depends_on =  [azurerm_key_vault.vault]
}

# Create virtual network
resource "azurerm_virtual_network" "ansible_network" {
  name                = "myVnet"
  address_space       = ["10.0.0.0/16"]
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
}

# Create subnet
resource "azurerm_subnet" "ansible_subnet" {
  name                 = "ansibleSubnet"
  resource_group_name  = azurerm_resource_group.rg.name
  virtual_network_name = azurerm_virtual_network.ansible_network.name
  address_prefixes     = ["10.0.1.0/24"]
}

# Create public IPs
resource "azurerm_public_ip" "ansible_publicip" {
  name                = "myPublicIP"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  allocation_method   = "Dynamic"
}

# Create Network Security Group and rule
resource "azurerm_network_security_group" "ansible_nsg" {
  name                = "AnsibleNetworkSecurityGroup"
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
    name                       = "RDP"
    priority                   = 1002
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "3389"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }
}

# Connect the security group to the subnet
resource "azurerm_subnet_network_security_group_association" "ansible_fwrule" {
  depends_on                = [azurerm_network_security_group.ansible_nsg]
  subnet_id                 = azurerm_subnet.ansible_subnet.id
  network_security_group_id = azurerm_network_security_group.ansible_nsg.id
}

# Create network interface for Linux VM
resource "azurerm_network_interface" "ado_agent_nic" {
  name                = "ado_agent_nic"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name

  ip_configuration {
    name                          = "ado_agent_nic_config"
    subnet_id                     = azurerm_subnet.ansible_subnet.id
    private_ip_address_allocation = "Dynamic"
    #public_ip_address_id          = azurerm_public_ip.ansible_publicip.id
  }
}

# Create Linux virtual machine
resource "azurerm_linux_virtual_machine" "ado_agent_vm" {
  depends_on =  [azurerm_key_vault.vault]
  name                  = "adoAgentVm"
  location              = azurerm_resource_group.rg.location
  resource_group_name   = azurerm_resource_group.rg.name
  network_interface_ids = [azurerm_network_interface.ado_agent_nic.id]
  size                  = "Standard_B2ms"

  os_disk {
    name                 = "ADO_OsDisk"
    caching              = "ReadWrite"
    storage_account_type = "Standard_LRS"
  }

  source_image_reference {
    publisher = "Canonical"
    offer     = "0001-com-ubuntu-server-jammy"
    sku       = "22_04-lts-gen2"
    version   = "latest"
  }

  computer_name                   = "adoAgentVm"
  admin_username                  = "testadmin"
  admin_password                  =  azurerm_key_vault_secret.key.value
  disable_password_authentication = false

}

# Create network interface for Windows VM
resource "azurerm_network_interface" "windows_nic" {
  name                = "win_nic"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name

  ip_configuration {
    name                          = "win_nic_config"
    subnet_id                     = azurerm_subnet.ansible_subnet.id
    private_ip_address_allocation = "Dynamic"
    public_ip_address_id          = azurerm_public_ip.ansible_publicip.id
  }
}

# Create Windows virtual machine
resource "azurerm_windows_virtual_machine" "main" {
  depends_on            = [azurerm_key_vault.vault]
  name                  = "windowsVM"
  admin_username        = "testadmin"
  admin_password        = azurerm_key_vault_secret.key.value
  location              = azurerm_resource_group.rg.location
  resource_group_name   = azurerm_resource_group.rg.name
  network_interface_ids = [azurerm_network_interface.windows_nic.id]
  size                  = "Standard_B2ms"

  os_disk {
    name                 = "WinOsDisk"
    caching              = "ReadWrite"
    storage_account_type = "Standard_LRS"
  }

  source_image_reference {
    publisher = "MicrosoftWindowsServer"
    offer     = "WindowsServer"
    sku       = "2022-datacenter-azure-edition"
    version   = "latest"
  }

}