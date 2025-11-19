resource "azurerm_linux_virtual_machine_scale_set" "masters" {
  name                   = var.vmss_name
  location               = var.location
  resource_group_name    = var.resource_group_name
  sku                    = var.vm_size
  instances              = var.instance_count
  admin_username         = var.admin_username
  overprovision          = false
  single_placement_group = true
  upgrade_mode           = "Manual"
  tags                   = var.tags

  admin_ssh_key {
    username   = var.admin_username
    public_key = var.ssh_public_key
  }

  source_image_reference {
    publisher = "Canonical"
    offer     = "0001-com-ubuntu-server-jammy"
    sku       = "22_04-lts-gen2"
    version   = "latest"
  }

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Premium_LRS"
    disk_size_gb         = var.os_disk_size_gb
  }

  network_interface {
    name                 = "master-nic"
    primary              = true
    enable_ip_forwarding = true

    ip_configuration {
      name      = "ipconfig1"
      primary   = true
      subnet_id = var.subnet_id

      load_balancer_backend_address_pool_ids = [var.lb_backend_pool_id]
    }
  }

  identity {
    type = "UserAssigned"
    identity_ids = [
      var.managed_identity_id
    ]
  }

  disable_password_authentication = true

  extension {
    name                       = "k8s-master-config"
    publisher                  = "Microsoft.Azure.Extensions"
    type                       = "CustomScript"
    type_handler_version       = "2.1"
    auto_upgrade_minor_version = true

    protected_settings = jsonencode({
      script = base64encode(var.init_script)
    })
  }

  health_probe_id = var.health_probe_id
}
