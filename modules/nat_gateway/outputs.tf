output "nat_gateway_id" {
  description = "NAT Gateway ID"
  value       = azurerm_nat_gateway.this.id
}

output "nat_gateway_name" {
  description = "NAT Gateway name"
  value       = azurerm_nat_gateway.this.name
}

output "public_ip_address" {
  description = "NAT Gateway public IP address"
  value       = azurerm_public_ip.nat.ip_address
}
