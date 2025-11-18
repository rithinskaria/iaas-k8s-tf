output "name" {
  description = "The name of the virtual network"
  value       = azurerm_virtual_network.this.name
}

output "id" {
  description = "The resource ID of the virtual network"
  value       = azurerm_virtual_network.this.id
}

output "subnets" {
  description = "The subnets in the virtual network"
  value = [for subnet in azurerm_subnet.subnets : {
    name           = subnet.name
    id             = subnet.id
    address_prefix = subnet.address_prefixes[0]
  }]
}

output "subnet_ids" {
  description = "Map of subnet names to IDs"
  value = { for name, subnet in azurerm_subnet.subnets : name => subnet.id }
}
