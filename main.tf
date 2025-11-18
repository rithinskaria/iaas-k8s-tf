data "azurerm_client_config" "current" {}


resource "azurerm_resource_provider_registration" "kubernetes" {
  name = "Microsoft.Kubernetes"
}

resource "random_string" "kv_suffix" {
  length  = 5
  special = false
  upper   = false
}

locals {
  key_vault_name = "${var.key_vault_base_name}-${random_string.kv_suffix.result}"
  
  # Determine VM type based on worker count
  vm_type = var.worker_node_count > 0 ? "vmss" : "standard"
  
  # Load initialization scripts from external files
  master_init_script = templatefile("${path.module}/scripts/master-init.sh", {
    KEY_VAULT_NAME      = local.key_vault_name
    RESOURCE_GROUP_NAME = var.resource_group_name
    ARC_CLUSTER_NAME    = var.arc_cluster_name
    LOCATION            = var.location
    VM_TYPE             = local.vm_type
    VNET_NAME           = var.vnet_name
    SUBNET_NAME         = var.k8s_subnet_name
    NSG_NAME            = "nsg-k8s-subnet"
    MI_CLIENT_ID        = module.k8s_identity.client_id
  })

  worker_init_script = templatefile("${path.module}/scripts/worker-init.sh", {
    KEY_VAULT_NAME      = local.key_vault_name
    RESOURCE_GROUP_NAME = var.resource_group_name
    LOCATION            = var.location
    VM_TYPE             = local.vm_type
    VNET_NAME           = var.vnet_name
    SUBNET_NAME         = var.k8s_subnet_name
    NSG_NAME            = "nsg-k8s-subnet"
    MI_CLIENT_ID        = module.k8s_identity.client_id
  })
}

module "resource_group" {
  source = "./modules/resource_group"

  name     = var.resource_group_name
  location = var.location
  tags     = var.tags
}


module "k8s_identity" {
  source = "./modules/managed_identity"

  location            = var.location
  resource_group_name = module.resource_group.name
  identity_name       = "id-k8s-vms"
  tags                = var.tags

  depends_on = [module.resource_group]
}

resource "azurerm_role_assignment" "k8s_identity_network_contributor" {
  scope                = module.resource_group.id
  role_definition_name = "Network Contributor"
  principal_id         = module.k8s_identity.principal_id

  depends_on = [module.k8s_identity]
}

resource "azurerm_role_assignment" "k8s_identity_arc_onboarding" {
  scope                = module.resource_group.id
  role_definition_name = "Kubernetes Cluster - Azure Arc Onboarding"
  principal_id         = module.k8s_identity.principal_id

  depends_on = [module.k8s_identity]
}

module "vnet" {
  source = "./modules/virtual_network"

  name                = var.vnet_name
  location            = var.location
  resource_group_name = module.resource_group.name
  address_prefix      = var.vnet_address_prefix
  tags                = var.tags

  subnets = [
    {
      name           = var.k8s_subnet_name
      address_prefix = var.k8s_subnet_prefix
    },
    {
      name           = "AzureBastionSubnet"
      address_prefix = var.bastion_subnet_prefix
    }
  ]

  depends_on = [module.resource_group]
}

module "k8s_nsg" {
  source = "./modules/network_security_group"

  name                   = "nsg-k8s-subnet"
  location               = var.location
  resource_group_name    = module.resource_group.name
  subnet_id              = module.vnet.subnet_ids[var.k8s_subnet_name]
  vnet_address_prefix    = var.vnet_address_prefix
  allow_ssh_from_prefix  = "VirtualNetwork"
  tags                   = var.tags

  depends_on = [module.vnet]
}

module "key_vault" {
  source = "./modules/key_vault"

  location                      = var.location
  resource_group_name           = module.resource_group.name
  key_vault_name                = local.key_vault_name
  tags                          = var.tags
  tenant_id                     = data.azurerm_client_config.current.tenant_id
  managed_identity_principal_id = module.k8s_identity.principal_id
  enable_rbac_authorization     = true

  depends_on = [module.resource_group]
}

module "bastion" {
  source = "./modules/bastion"

  name                = var.bastion_name
  location            = var.location
  resource_group_name = module.resource_group.name
  bastion_subnet_id   = module.vnet.subnet_ids["AzureBastionSubnet"]
  tags                = var.tags
  sku_name            = var.bastion_sku_name

  depends_on = [module.vnet]
}


module "master_node" {
  source = "./modules/master_node"

  location            = var.location
  resource_group_name = module.resource_group.name
  subnet_id           = module.vnet.subnet_ids[var.k8s_subnet_name]
  tags                = var.tags
  admin_username      = var.admin_username
  ssh_public_key      = var.ssh_public_key
  vm_size             = var.vm_size
  master_name         = "k8s-master"
  managed_identity_id = module.k8s_identity.identity_id
  os_disk_size_gb     = var.os_disk_size_gb
  init_script         = local.master_init_script

  depends_on = [module.key_vault]
}


module "worker_vmss" {
  source = "./modules/worker_vmss"

  location            = var.location
  resource_group_name = module.resource_group.name
  subnet_id           = module.vnet.subnet_ids[var.k8s_subnet_name]
  tags                = var.tags
  admin_username      = var.admin_username
  ssh_public_key      = var.ssh_public_key
  vm_size             = var.vm_size
  vmss_name           = "vmss-k8s-workers"
  instance_count      = var.worker_node_count
  managed_identity_id = module.k8s_identity.identity_id
  os_disk_size_gb     = var.os_disk_size_gb
  init_script         = local.worker_init_script

  depends_on = [
    module.key_vault,
    module.master_node
  ]
}
