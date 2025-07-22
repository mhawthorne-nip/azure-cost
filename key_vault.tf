resource "azurerm_key_vault" "cost_management" {
  name                        = "kv-${var.environment}-cost-${random_string.suffix.result}"
  location                    = azurerm_resource_group.cost_management.location
  resource_group_name         = azurerm_resource_group.cost_management.name
  enabled_for_disk_encryption = true
  enable_rbac_authorization   = true
  purge_protection_enabled    = false # Set to false for MVP to allow easy cleanup
  soft_delete_retention_days  = 7     # Minimum for MVP
  tenant_id                   = data.azurerm_client_config.current.tenant_id
  sku_name                    = "standard"

  tags = local.common_tags
}

# Grant Key Vault access to the automation account's managed identity
resource "azurerm_role_assignment" "automation_key_vault_secrets_user" {
  scope                = azurerm_key_vault.cost_management.id
  role_definition_name = "Key Vault Secrets User"
  principal_id         = azurerm_automation_account.cost_management.identity[0].principal_id
}
