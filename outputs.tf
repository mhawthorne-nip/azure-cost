output "resource_group_name" {
  description = "The name of the resource group"
  value       = azurerm_resource_group.cost_management.name
}

output "automation_account_name" {
  description = "The name of the automation account"
  value       = azurerm_automation_account.cost_management.name
}

output "log_analytics_workspace_id" {
  description = "The ID of the Log Analytics workspace"
  value       = azurerm_log_analytics_workspace.cost_management.id
}

output "log_analytics_workspace_name" {
  description = "The name of the Log Analytics workspace"
  value       = azurerm_log_analytics_workspace.cost_management.name
}

output "storage_account_name" {
  description = "The name of the storage account"
  value       = azurerm_storage_account.cost_management_data.name
}

output "key_vault_name" {
  description = "The name of the key vault"
  value       = azurerm_key_vault.cost_management.name
}

output "key_vault_uri" {
  description = "The URI of the key vault"
  value       = azurerm_key_vault.cost_management.vault_uri
}

output "automation_account_identity_principal_id" {
  description = "The principal ID of the automation account's managed identity"
  value       = azurerm_automation_account.cost_management.identity[0].principal_id
}

output "powershell_runtime_environment_name" {
  description = "The name of the PowerShell 7.4 runtime environment"
  value       = azapi_resource.powershell_runtime_env.name
}

output "deployment_summary" {
  description = "Summary of deployed resources"
  value = {
    resource_group = azurerm_resource_group.cost_management.name
    location       = var.location
    environment    = var.environment
    cost_estimate  = "$3.53/month"
    powershell_version = "7.4"
    az_module_version = "12.3.0"
  }
}
