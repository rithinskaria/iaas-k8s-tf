variable "location" {
  description = "The Azure region where the Key Vault will be deployed"
  type        = string
}

variable "key_vault_name" {
  description = "The name of the Key Vault"
  type        = string
}

variable "resource_group_name" {
  description = "The name of the resource group"
  type        = string
}

variable "tags" {
  description = "Tags to apply to the Key Vault"
  type        = map(string)
  default     = {}
}

variable "tenant_id" {
  description = "The Azure AD tenant ID"
  type        = string
}

variable "managed_identity_principal_id" {
  description = "Principal ID of the managed identity that needs access to Key Vault"
  type        = string
}

variable "sku_name" {
  description = "SKU name for the Key Vault"
  type        = string
  default     = "standard"
  validation {
    condition     = contains(["standard", "premium"], var.sku_name)
    error_message = "SKU must be standard or premium."
  }
}

variable "enable_rbac_authorization" {
  description = "Whether to enable RBAC authorization"
  type        = bool
  default     = true
}
