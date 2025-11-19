output "resource_group_name" {
  description = "The name of the resource group"
  value       = module.resource_group.name
}

output "resource_group_id" {
  description = "The resource ID of the resource group"
  value       = module.resource_group.id
}

output "resource_group_location" {
  description = "The location of the resource group"
  value       = module.resource_group.location
}

output "vnet_name" {
  description = "The name of the virtual network"
  value       = module.vnet.name
}

output "vnet_id" {
  description = "The resource ID of the virtual network"
  value       = module.vnet.id
}

output "subnets" {
  description = "The subnets in the virtual network"
  value       = module.vnet.subnets
}

output "bastion_name" {
  description = "The name of the Azure Bastion"
  value       = module.bastion.name
}

output "bastion_id" {
  description = "The resource ID of the Azure Bastion"
  value       = module.bastion.id
}

output "bastion_public_ip_address" {
  description = "The public IP address of the Azure Bastion"
  value       = module.bastion.public_ip_address
}

output "load_balancer" {
  description = "Load balancer details for API server"
  value = {
    id                  = module.load_balancer.lb_id
    frontend_ip         = module.load_balancer.frontend_ip
    api_server_endpoint = module.load_balancer.api_server_endpoint
  }
}

output "master_vmss" {
  description = "Master VMSS details"
  value = {
    name           = module.master_vmss.vmss_name
    id             = module.master_vmss.vmss_id
    instance_count = var.master_count
  }
}

output "worker_vmss" {
  description = "Worker VMSS details"
  value = {
    name           = module.worker_vmss.name
    id             = module.worker_vmss.id
    instance_count = module.worker_vmss.instance_count
  }
}

output "api_server_endpoint" {
  description = "Kubernetes API server endpoint (use this to connect to the cluster)"
  value       = module.load_balancer.api_server_endpoint
}

output "cluster_mode" {
  description = "Cluster mode (single-master or HA)"
  value       = var.master_count == 1 ? "single-master" : "HA (3 masters)"
}

output "key_vault_name" {
  description = "The name of the Key Vault"
  value       = module.key_vault.key_vault_name
}

output "key_vault_uri" {
  description = "The URI of the Key Vault"
  value       = module.key_vault.key_vault_uri
}
