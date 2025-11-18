variable "location" {}

variable "resource_group_name" {}

variable "subnet_id" {}

variable "tags" {
  description = "Tags to apply to the master VM"
  type        = map(string)
  default     = {}
}

variable "admin_username" {
  description = "The admin username for the VM"
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

variable "master_name" {
  description = "The name of the master VM"
  type        = string
  default     = "k8s-master"
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
  description = "Initialization script to run on master VM"
  type        = string
}
