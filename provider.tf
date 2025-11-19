terraform {

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "> 4.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "> 3.6"
    }
  }
}

provider "azurerm" {
  subscription_id = "d1e69bd8-2fe1-42bc-a3a7-ca4469cb5167"
  features {
    resource_group {
      prevent_deletion_if_contains_resources = false
    }
  }
}
