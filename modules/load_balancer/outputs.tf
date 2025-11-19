output "lb_id" {
  description = "Load balancer ID"
  value       = azurerm_lb.k8s_api.id
}

output "backend_pool_id" {
  description = "Backend address pool ID"
  value       = azurerm_lb_backend_address_pool.k8s_masters.id
}

output "health_probe_id" {
  description = "Health probe ID"
  value       = azurerm_lb_probe.k8s_api_health.id
}

output "frontend_ip" {
  description = "Frontend IP address (API server endpoint)"
  value       = var.frontend_ip
}

output "api_server_endpoint" {
  description = "Full API server endpoint"
  value       = "${var.frontend_ip}:6443"
}
