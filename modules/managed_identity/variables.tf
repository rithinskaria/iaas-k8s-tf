variable "location" {
  description = "The Azure region where the managed identity will be deployed"
  type        = string
}

variable "identity_name" {
  description = "The name of the managed identity"
  type        = string
}

variable "tags" {
  description = "Tags to apply to the managed identity"
  type        = map(string)
  default     = {}
}

variable "resource_group_name" {
  description = "The name of the resource group"
  type        = string
}
