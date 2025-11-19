resource "azurerm_lb" "k8s_api" {
  name                = var.lb_name
  location            = var.location
  resource_group_name = var.resource_group_name
  sku                 = "Standard"
  tags                = var.tags

  frontend_ip_configuration {
    name                          = "k8s-api-frontend"
    subnet_id                     = var.subnet_id
    private_ip_address_allocation = "Static"
    private_ip_address            = var.frontend_ip
  }
}

resource "azurerm_lb_backend_address_pool" "k8s_masters" {
  name            = "k8s-master-pool"
  loadbalancer_id = azurerm_lb.k8s_api.id
}

resource "azurerm_lb_probe" "k8s_api_health" {
  name                = "k8s-api-health"
  loadbalancer_id     = azurerm_lb.k8s_api.id
  protocol            = "Tcp"
  port                = 6443
  interval_in_seconds = 5
  number_of_probes    = 2
}

resource "azurerm_lb_rule" "k8s_api" {
  name                           = "k8s-api-rule"
  loadbalancer_id                = azurerm_lb.k8s_api.id
  protocol                       = "Tcp"
  frontend_port                  = 6443
  backend_port                   = 6443
  frontend_ip_configuration_name = "k8s-api-frontend"
  backend_address_pool_ids       = [azurerm_lb_backend_address_pool.k8s_masters.id]
  probe_id                       = azurerm_lb_probe.k8s_api_health.id
  floating_ip_enabled            = false
  idle_timeout_in_minutes        = 4
  load_distribution              = "Default"
}
