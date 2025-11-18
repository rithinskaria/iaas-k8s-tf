output "name" {
  description = "Master VM name"
  value       = azurerm_linux_virtual_machine.master.name
}

output "id" {
  description = "Master VM resource ID"
  value       = azurerm_linux_virtual_machine.master.id
}

output "private_ip_address" {
  description = "Master VM private IP address"
  value       = azurerm_network_interface.master.private_ip_address
}
