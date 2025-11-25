variable "location" { default     = "eastus" }

variable "resource_group_name" {}
variable "vnet_name" {}
variable "vnet_address_prefix" {}
variable "master_subnet_name" {}
variable "master_subnet_prefix" {}
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

variable "node_pools" {
  description = "Map of node pools with their configurations"
  type = map(object({
    subnet_prefix   = string
    vm_size         = string
    node_count      = number
    os_disk_size_gb = optional(number, 128)
    nsg_name        = optional(string, "nsg-k8s-worker-subnet")  # Default to shared NSG
    taints = optional(list(object({
      key    = string
      value  = string
      effect = string  # NoSchedule, PreferNoSchedule, NoExecute
    })), [])
    labels = optional(map(string), {})
  }))
  
  validation {
    condition     = alltrue([for pool in var.node_pools : pool.node_count >= 1 && pool.node_count <= 10])
    error_message = "Each node pool's node_count must be between 1 and 10."
  }
  
  validation {
    condition     = alltrue([for pool in var.node_pools : pool.os_disk_size_gb >= 30 && pool.os_disk_size_gb <= 2048])
    error_message = "Each node pool's os_disk_size_gb must be between 30 and 2048 GB."
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

variable "cni_type" {
  description = "CNI type to install: 1 = Calico, 2 = Cilium + Istio"
  type        = number
  default     = 2
  validation {
    condition     = contains([1, 2], var.cni_type)
    error_message = "CNI type must be 1 (Calico) or 2 (Cilium + Istio)."
  }
}
