resource "azurerm_storage_account" "cost_management_data" {
  name                     = "st${replace(var.project_name, "-", "")}${var.environment}${random_string.suffix.result}"
  resource_group_name      = azurerm_resource_group.cost_management.name
  location                 = azurerm_resource_group.cost_management.location
  account_tier             = "Standard"
  account_replication_type = "ZRS"
  account_kind             = "StorageV2"

  https_traffic_only_enabled = true
  min_tls_version            = "TLS1_2"

  blob_properties {
    versioning_enabled = true

    delete_retention_policy {
      days = 7
    }

    container_delete_retention_policy {
      days = 7
    }
  }

  tags = local.common_tags
}

resource "azurerm_storage_container" "cost_data" {
  name                  = "cost-data"
  storage_account_name  = azurerm_storage_account.cost_management_data.name
  container_access_type = "private"
}

resource "azurerm_storage_container" "reports" {
  name                  = "reports"
  storage_account_name  = azurerm_storage_account.cost_management_data.name
  container_access_type = "private"
}
