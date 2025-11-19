output "vmss_id" {
  description = "Master VMSS ID"
  value       = azurerm_linux_virtual_machine_scale_set.masters.id
}

output "vmss_name" {
  description = "Master VMSS name"
  value       = azurerm_linux_virtual_machine_scale_set.masters.name
}
