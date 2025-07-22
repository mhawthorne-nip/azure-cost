data "azurerm_client_config" "current" {}

data "azurerm_subscription" "primary" {
  subscription_id = var.management_subscription_id
}

resource "random_string" "suffix" {
  length  = 6
  special = false
  upper   = false
}

locals {
  common_tags = {
    Environment  = var.environment
    Project      = var.project_name
    ProjectOwner = var.project_owner
    CostCenter   = var.cost_center
    ManagedBy    = "Terraform"
    Purpose      = "CostManagement"
  }
}
