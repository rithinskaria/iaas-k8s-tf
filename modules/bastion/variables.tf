variable "name" {
  description = "The name of the Azure Bastion"
  type        = string
}

variable "location" {
  description = "The Azure region where the Azure Bastion will be deployed"
  type        = string
}

variable "resource_group_name" {
  description = "The name of the resource group"
  type        = string
}

variable "bastion_subnet_id" {
  description = "The resource ID of the Azure Bastion subnet"
  type        = string
}

variable "tags" {
  description = "Tags to apply to the Azure Bastion"
  type        = map(string)
  default     = {}
}

variable "sku_name" {
  description = "The name of the SKU for Azure Bastion"
  type        = string
  validation {
    condition     = contains(["Basic", "Standard", "Premium"], var.sku_name)
    error_message = "SKU must be Basic, Standard, or Premium."
  }
}
