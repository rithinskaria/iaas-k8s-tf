variable "vmss_name" {
  description = "Name of the master VMSS"
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
  description = "Subnet ID for master VMs"
  type        = string
}

variable "vm_size" {
  description = "VM size for master nodes"
  type        = string
}

variable "instance_count" {
  description = "Number of master instances (1 or 3 for HA)"
  type        = number
  default     = 3

  validation {
    condition     = contains([1, 3], var.instance_count)
    error_message = "Master count must be 1 (single master) or 3 (HA)."
  }
}

variable "admin_username" {
  description = "Admin username for VMs"
  type        = string
}

variable "ssh_public_key" {
  description = "SSH public key for VM access"
  type        = string
  sensitive   = true
}

variable "os_disk_size_gb" {
  description = "OS disk size in GB"
  type        = number
  default     = 128
}

variable "managed_identity_id" {
  description = "Managed identity ID for the VMs"
  type        = string
}

variable "lb_backend_pool_id" {
  description = "Load balancer backend pool ID"
  type        = string
}

variable "health_probe_id" {
  description = "Load balancer health probe ID"
  type        = string
}

variable "init_script" {
  description = "Initialization script for master nodes"
  type        = string
}

variable "tags" {
  description = "Tags to apply to resources"
  type        = map(string)
  default     = {}
}
