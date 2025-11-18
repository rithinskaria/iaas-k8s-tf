output "name" {
  description = "VMSS name"
  value       = azurerm_linux_virtual_machine_scale_set.workers.name
}

output "id" {
  description = "VMSS resource ID"
  value       = azurerm_linux_virtual_machine_scale_set.workers.id
}

output "instance_count" {
  description = "VMSS instance count"
  value       = azurerm_linux_virtual_machine_scale_set.workers.instances
}
