output "name" {
  description = "The name of the resource group"
  value       = azurerm_resource_group.this.name
}

output "id" {
  description = "The resource ID of the resource group"
  value       = azurerm_resource_group.this.id
}

output "location" {
  description = "The location of the resource group"
  value       = azurerm_resource_group.this.location
}
