variable "name" {
  description = "The name of the network security group"
  type        = string
}

variable "location" {
  description = "The location/region where the network security group will be created"
  type        = string
}

variable "resource_group_name" {
  description = "The name of the resource group"
  type        = string
}

variable "tags" {
  description = "Tags to apply to the network security group"
  type        = map(string)
  default     = {}
}

variable "subnet_id" {
  description = "The subnet ID to associate with the NSG"
  type        = string
  default     = null
}

variable "allow_ssh_from_prefix" {
  description = "The address prefix to allow SSH from"
  type        = string
  default     = "VirtualNetwork"
}

variable "vnet_address_prefix" {
  description = "The VNet address prefix for internal communication"
  type        = string
}
