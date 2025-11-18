output "name" {
  description = "The name of the Azure Bastion"
  value       = azurerm_bastion_host.this.name
}

output "id" {
  description = "The resource ID of the Azure Bastion"
  value       = azurerm_bastion_host.this.id
}

output "public_ip_id" {
  description = "The public IP address ID of the Azure Bastion"
  value       = azurerm_public_ip.bastion.id
}

output "public_ip_address" {
  description = "The public IP address of the Azure Bastion"
  value       = azurerm_public_ip.bastion.ip_address
}
