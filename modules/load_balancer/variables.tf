variable "lb_name" {
  description = "Name of the load balancer"
  type        = string
}

variable "location" {
  description = "Azure region"
  type        = string
}

variable "resource_group_name" {
  description = "Resource group name"
  type        = string
}

variable "subnet_id" {
  description = "Subnet ID for the load balancer frontend"
  type        = string
}

variable "frontend_ip" {
  description = "Static private IP for the load balancer frontend (API server endpoint)"
  type        = string
}

variable "tags" {
  description = "Tags to apply to resources"
  type        = map(string)
  default     = {}
}
