variable "location" { default = "eastus" }

variable "resource_group_name" {}
variable "vnet_name" {}
variable "vnet_address_prefix" {}
variable "k8s_subnet_name" {}
variable "k8s_subnet_prefix" {}
variable "bastion_subnet_prefix" {}
variable "bastion_name" {}
variable "bastion_sku_name" {
  default = "Standard"
  validation {
    condition     = contains(["Basic", "Standard", "Premium"], var.bastion_sku_name)
    error_message = "Bastion SKU must be Basic, Standard, or Premium."
  }
}

variable "ssh_public_key" {
  sensitive = true
}
variable "admin_username" {}
variable "vm_size" {}

variable "key_vault_base_name" {
  default = "kv-k8s-dev-cc"
}

variable "arc_cluster_name" {
  description = "Name for the Azure Arc-enabled Kubernetes cluster"
  type        = string
  default     = "arc-k8s-cluster"
}

variable "worker_node_count" {
  description = "Number of worker nodes to create"
  type        = number
  default     = 2
  validation {
    condition     = var.worker_node_count >= 1 && var.worker_node_count <= 10
    error_message = "Worker node count must be between 1 and 10."
  }
}
variable "os_disk_size_gb" {
  description = "OS disk size in GB for VMs"
  type        = number
  default     = 128
  validation {
    condition     = var.os_disk_size_gb >= 30 && var.os_disk_size_gb <= 2048
    error_message = "OS disk size must be between 30 and 2048 GB."
  }
}

variable "master_count" {
  description = "Number of master nodes (1 for single master, 3 for HA)"
  type        = number
  default     = 3
  validation {
    condition     = contains([1, 3], var.master_count)
    error_message = "Master count must be either 1 (single master) or 3 (HA mode)."
  }
}

variable "control_plane_endpoint" {
  description = "Static IP address for the control plane endpoint (load balancer frontend)"
  type        = string
  default     = "10.0.0.50"
  validation {
    condition     = can(regex("^(?:[0-9]{1,3}\\.){3}[0-9]{1,3}$", var.control_plane_endpoint))
    error_message = "Control plane endpoint must be a valid IP address."
  }
}

variable "tags" {
  description = "Tags to apply to resources"
  type        = map(string)
  default     = {}
}

variable "enable_arc" {
  description = "Enable Azure Arc onboarding after cluster deployment"
  type        = bool
  default     = true
}
