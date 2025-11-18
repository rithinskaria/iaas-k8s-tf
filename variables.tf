variable "location" { default     = "eastus" }

variable "resource_group_name" {}
variable "vnet_name" {}
variable "vnet_address_prefix" {}
variable "k8s_subnet_name" {}
variable "k8s_subnet_prefix" {}
variable "bastion_subnet_prefix" {}
variable "bastion_name" {}
variable "bastion_sku_name" {
  default     = "Standard"
  validation {
    condition     = contains(["Basic", "Standard", "Premium"], var.bastion_sku_name)
    error_message = "Bastion SKU must be Basic, Standard, or Premium."
  }
}

variable "ssh_public_key" {
  sensitive   = true
}
variable "admin_username" {}
variable "vm_size" {}

variable "key_vault_base_name" {
  default     = "kv-k8s-dev-cc"
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

variable "tags" {
  description = "Tags to apply to resources"
  type        = map(string)
  default     = {}
}
