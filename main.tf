# We strongly recommend using the required_providers block to set the
# Azure Provider source and version being used
terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "=3.0.0"
    }
  }
}

# Configure the Microsoft Azure Provider
provider "azurerm" {
  features {}
}

# Create a resource group
resource "azurerm_resource_group" "rafi-rg" {
  name     = "rafi-resources"
  location = "Central India"
}

# Create a virtual network within the resource group
resource "azurerm_virtual_network" "rafi-vnet" {
  name                = "rafi-network"
  resource_group_name = azurerm_resource_group.rafi-rg.name
  location            = azurerm_resource_group.rafi-rg.location
  address_space       = ["10.0.0.0/16"]
}

#application gateway requires a subnet
resource "azurerm_subnet" "frontend" {
  name                 = "appgw-subnet"
  resource_group_name  = azurerm_resource_group.rafi-rg.name
  virtual_network_name = azurerm_virtual_network.rafi-vnet.name
  address_prefixes     = ["10.0.1.0/24"]
}

resource "azurerm_subnet" "backend" {
  name                 = "vm-subnet"
  resource_group_name  = azurerm_resource_group.rafi-rg.name
  virtual_network_name = azurerm_virtual_network.rafi-vnet.name
  address_prefixes     = ["10.0.1.0/24"]
}

resource "azurerm_network_security_group" "rafi-sg" {
  name                = "acceptanceTestSecurityGroup1"
  location            = azurerm_resource_group.rafi-rg.location
  resource_group_name = azurerm_resource_group.rafi-rg.name

  security_rule {
    name                       = "security-rule"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "*" #allows all protocols
    source_port_range          = "*"
    destination_port_range     = "*"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }

  tags = {
    environment = "dev"
  }
}

# resource "azurerm_subnet_network_security_group_association" "rafi-sga" {
#   subnet_id                 = azurerm_subnet.rafi-subnet.id
#   network_security_group_id = azurerm_network_security_group.rafi-sg.id
# }

resource "azurerm_public_ip" "rafi-pip" {
  name                = "vm-pip"
  resource_group_name = azurerm_resource_group.rafi-rg.name
  location            = azurerm_resource_group.rafi-rg.location
  allocation_method   = "Dynamic" #public ip will not show up until attached to some resource

  tags = {
    environment = "Production"
  }
}

locals {
  backend_address_pool_name      = "${azurerm_virtual_network.rafi-vnet.name}-beap"
  frontend_port_name             = "${azurerm_virtual_network.rafi-vnet.name}-feport"
  frontend_ip_configuration_name = "${azurerm_virtual_network.rafi-vnet.name}-feip"
  http_setting_name              = "${azurerm_virtual_network.rafi-vnet.name}-be-htst"
  listener_name                  = "${azurerm_virtual_network.rafi-vnet.name}-httplstn"
  request_routing_rule_name      = "${azurerm_virtual_network.rafi-vnet.name}-rqrt"
  redirect_configuration_name    = "${azurerm_virtual_network.rafi-vnet.name}-rdrcfg"
}

resource "azurerm_application_gateway" "rafi-ag" {
  name                = "appgateway"
  resource_group_name = azurerm_resource_group.rafi-rg.name
  location            = azurerm_resource_group.rafi-rg.location

  sku {
    name     = "Standard_Small"
    tier     = "Standard"
    capacity = 2
  }

  gateway_ip_configuration {
    name      = "my-gateway-ip-configuration"
    subnet_id = azurerm_subnet.frontend.id
  }

  frontend_port {
    name = local.frontend_port_name
    port = 80
  }

  frontend_ip_configuration {
    name                 = local.frontend_ip_configuration_name
    public_ip_address_id = azurerm_public_ip.rafi-pip.id
  }

  backend_address_pool {
    name = local.backend_address_pool_name
  }

  backend_http_settings {
    name                  = local.http_setting_name
    cookie_based_affinity = "Disabled"
    path                  = "/path1/"
    port                  = 80
    protocol              = "Http"
    request_timeout       = 60
  }

  http_listener {
    name                           = local.listener_name
    frontend_ip_configuration_name = local.frontend_ip_configuration_name
    frontend_port_name             = local.frontend_port_name
    protocol                       = "Http"
  }

  request_routing_rule {
    name                       = local.request_routing_rule_name
    rule_type                  = "Basic"
    http_listener_name         = local.listener_name
    backend_address_pool_name  = local.backend_address_pool_name
    backend_http_settings_name = local.http_setting_name
  }
}

resource "azurerm_network_interface" "rafi-nic" {
  name                = "nic"
  location            = azurerm_resource_group.rafi-rg.location
  resource_group_name = azurerm_resource_group.rafi-rg.name

  ip_configuration {
    name                          = "nic-ipconfig"
    subnet_id                     = azurerm_subnet.backend.id
    private_ip_address_allocation = "Dynamic"
  }
}


resource "azurerm_network_interface_application_gateway_backend_address_pool_association" "nic-assoc" {
  network_interface_id    = azurerm_network_interface.rafi-nic.id
  ip_configuration_name   = "nic-ipconfig"
  backend_address_pool_id = one(azurerm_application_gateway.rafi-ag.backend_address_pool).id
}

#windows vm
resource "azurerm_windows_virtual_machine" "vm" {
  name                = "myVM"
  resource_group_name = azurerm_resource_group.rafi-rg.name
  location            = azurerm_resource_group.rafi-rg.location
  size                = "Standard_DS1_v2"
  admin_username      = "azureadmin"
  network_interface_ids = [
    azurerm_network_interface.rafi-nic.id,
  ]

  #connect to the vm using ssh
  admin_ssh_key {
    username   = "adminuser"
    public_key = file("~/.ssh/id_rsa.pub") #file function gets the content from the rsa file
    #this is stored in the local machinet
  }
  
  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Standard_LRS"
  }


  source_image_reference {
    publisher = "MicrosoftWindowsServer"
    offer     = "WindowsServer"
    sku       = "2019-Datacenter"
    version   = "latest"
  }
}

# resource "azurerm_linux_virtual_machine" "rafi-vm" {
#   name                = ""
#   resource_group_name = azurerm_resource_group.rafi-rg.name
#   location            = azurerm_resource_group.rafi-rg.location
#   size                = "Standard_F2"
#   admin_username      = "adminuser"
#   network_interface_ids = [
#     azurerm_network_interface.rafi-nic.id,
#   ]
#   #connect to the vm using ssh
#   admin_ssh_key {                              
#     username   = "adminuser"
#     public_key = file("~/.ssh/id_rsa.pub") #file function gets the content from the rsa file
#                                            #this is stored in the local machinet
#   }

#   os_disk {
#     caching              = "ReadWrite"
#     storage_account_type = "Standard_LRS"
#   }

#   source_image_reference {
#     publisher = "Canonical"
#     offer     = "UbuntuServer"
#     sku       = "16.04-LTS"
#     version   = "latest"
#   }
# }