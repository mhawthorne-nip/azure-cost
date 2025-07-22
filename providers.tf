terraform {
  required_version = ">= 1.3"
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 3.0"
    }
    azapi = {
      source  = "Azure/azapi"
      version = "~> 1.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.1"
    }
  }

  backend "azurerm" {
    resource_group_name  = "rg-nip-tfstate-eus"
    storage_account_name = "niptfstate"
    container_name       = "tfstate"
    key                  = "costing/dev/terraform.tfstate"
    subscription_id      = "07621a69-8891-41c2-808e-e46b444bce0d"
    use_azuread_auth     = true
  }
}

# Use Azure CLI authentication for testing
provider "azurerm" {
  features {}
  subscription_id = var.management_subscription_id
  # Using Azure CLI authentication - no service principal needed for testing
}

# AzAPI provider for custom Log Analytics table creation
provider "azapi" {
  subscription_id = var.management_subscription_id
  # Using Azure CLI authentication
}

provider "random" {}
