variable "location" {
  description = "The Azure region where the worker VMSS will be deployed"
  type        = string
}

variable "resource_group_name" {
  description = "The name of the resource group"
  type        = string
}

variable "subnet_id" {
  description = "The resource ID of the subnet where worker VMSS will be deployed"
  type        = string
}

variable "tags" {
  description = "Tags to apply to the worker VMSS"
  type        = map(string)
  default     = {}
}

variable "admin_username" {
  description = "The admin username for the VMs"
  type        = string
}

variable "ssh_public_key" {
  description = "SSH public key for VM authentication"
  type        = string
  sensitive   = true
}

variable "vm_size" {
  description = "VM size/SKU"
  type        = string
}

variable "vmss_name" {
  description = "Name of the VMSS"
  type        = string
  default     = "vmss-k8s-workers"
}

variable "instance_count" {
  description = "Number of worker node instances"
  type        = number
  default     = 2
}

variable "managed_identity_id" {
  description = "The resource ID of the managed identity to use"
  type        = string
}

variable "os_disk_size_gb" {
  description = "OS disk size in GB"
  type        = number
  default     = 128
}

variable "init_script" {
  description = "Initialization script to run on worker VMs"
  type        = string
}
