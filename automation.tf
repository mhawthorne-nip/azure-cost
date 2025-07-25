resource "azurerm_automation_account" "cost_management" {
  name                = "aa-${var.project_name}-${var.environment}-${var.location_abbreviation}"
  location            = azurerm_resource_group.cost_management.location
  resource_group_name = azurerm_resource_group.cost_management.name
  sku_name            = "Basic" # Basic SKU for cost savings

  identity {
    type = "SystemAssigned"
  }

  tags = local.common_tags
}

# PowerShell 7.2 Runtime Environment with latest modules
resource "azapi_resource" "powershell_runtime_env" {
  type      = "Microsoft.Automation/automationAccounts/runtimeEnvironments@2023-05-15-preview"
  name      = "PowerShell72-Runtime"
  parent_id = azurerm_automation_account.cost_management.id
  location  = azurerm_resource_group.cost_management.location

  body = jsonencode({
    properties = {
      runtime = {
        language = "PowerShell"
        version  = "7.2"
      }
      description = "PowerShell 7.2 runtime environment with supported Az modules"
      defaultPackages = {
        "Az" = "11.2.0"
        "Azure CLI" = "2.56.0"
      }
    }
  })

  depends_on = [azurerm_automation_account.cost_management]
}

# Role assignments removed - manually managed (Billing Reader, Cost Management Reader)
# The following roles need to be assigned manually to the automation account managed identity:
# - Cost Management Reader (on target subscriptions)
# - Billing Reader (on management subscription)  
# - Reader (on target subscriptions, if needed for resource metadata)

# Grant Log Analytics Contributor role to write cost data
resource "azurerm_role_assignment" "automation_log_analytics_contributor" {
  scope                = azurerm_log_analytics_workspace.cost_management.id
  role_definition_name = "Log Analytics Contributor"
  principal_id         = azurerm_automation_account.cost_management.identity[0].principal_id
}

# Automation variables for secure storage
resource "azurerm_automation_variable_string" "log_analytics_workspace_id" {
  name                    = "LOG_ANALYTICS_WORKSPACE_ID"
  resource_group_name     = azurerm_resource_group.cost_management.name
  automation_account_name = azurerm_automation_account.cost_management.name
  value                   = azurerm_log_analytics_workspace.cost_management.workspace_id
  encrypted               = false
}

resource "azurerm_automation_variable_string" "log_analytics_workspace_key" {
  name                    = "LOG_ANALYTICS_WORKSPACE_KEY"
  resource_group_name     = azurerm_resource_group.cost_management.name
  automation_account_name = azurerm_automation_account.cost_management.name
  value                   = azurerm_log_analytics_workspace.cost_management.primary_shared_key
  encrypted               = true
}

# Email configuration variables
resource "azurerm_automation_variable_string" "email_from_address" {
  name                    = "EmailFromAddress"
  resource_group_name     = azurerm_resource_group.cost_management.name
  automation_account_name = azurerm_automation_account.cost_management.name
  value                   = var.email_from_address
  encrypted               = false
}

resource "azurerm_automation_variable_string" "email_client_id" {
  name                    = "EmailClientId"
  resource_group_name     = azurerm_resource_group.cost_management.name
  automation_account_name = azurerm_automation_account.cost_management.name
  value                   = var.email_client_id
  encrypted               = false
}

resource "azurerm_automation_variable_string" "email_tenant_id" {
  name                    = "EmailTenantId"
  resource_group_name     = azurerm_resource_group.cost_management.name
  automation_account_name = azurerm_automation_account.cost_management.name
  value                   = var.email_tenant_id
  encrypted               = false
}

resource "azurerm_automation_variable_string" "email_client_secret" {
  name                    = "EmailClientSecret"
  resource_group_name     = azurerm_resource_group.cost_management.name
  automation_account_name = azurerm_automation_account.cost_management.name
  value                   = var.email_client_secret
  encrypted               = true
}

# Cost report recipients
resource "azurerm_automation_variable_string" "cost_report_recipients" {
  name                    = "COST_REPORT_RECIPIENTS"
  resource_group_name     = azurerm_resource_group.cost_management.name
  automation_account_name = azurerm_automation_account.cost_management.name
  value                   = var.cost_report_recipients
  encrypted               = false
}

# Anthropic API key for AI analysis
resource "azurerm_automation_variable_string" "anthropic_api_key" {
  name                    = "ANTHROPIC_API_KEY"
  resource_group_name     = azurerm_resource_group.cost_management.name
  automation_account_name = azurerm_automation_account.cost_management.name
  value                   = var.anthropic_api_key
  encrypted               = true
}

# Target subscription IDs for cost collection
resource "azurerm_automation_variable_string" "target_subscription_ids" {
  name                    = "TARGET_SUBSCRIPTION_IDS"
  resource_group_name     = azurerm_resource_group.cost_management.name
  automation_account_name = azurerm_automation_account.cost_management.name
  value                   = join(",", var.target_subscription_ids)
  encrypted               = false
}

# Enhanced feature flags for the Weekly Analysis Engine v2.0
resource "azurerm_automation_variable_bool" "enable_advanced_prompting" {
  name                    = "ENABLE_ADVANCED_PROMPTING"
  resource_group_name     = azurerm_resource_group.cost_management.name
  automation_account_name = azurerm_automation_account.cost_management.name
  value                   = var.enable_advanced_prompting
  description            = "Enable Chain-of-Thought AI analysis with Claude"
}

resource "azurerm_automation_variable_bool" "include_anomaly_detection" {
  name                    = "INCLUDE_ANOMALY_DETECTION"
  resource_group_name     = azurerm_resource_group.cost_management.name
  automation_account_name = azurerm_automation_account.cost_management.name
  value                   = var.include_anomaly_detection
  description            = "Enable statistical anomaly detection in cost analysis"
}

resource "azurerm_automation_variable_bool" "include_chargeback_analysis" {
  name                    = "INCLUDE_CHARGEBACK_ANALYSIS"
  resource_group_name     = azurerm_resource_group.cost_management.name
  automation_account_name = azurerm_automation_account.cost_management.name
  value                   = var.include_chargeback_analysis
  description            = "Enable comprehensive chargeback and tag compliance analysis"
}

resource "azurerm_automation_variable_bool" "include_forecasting" {
  name                    = "INCLUDE_FORECASTING"
  resource_group_name     = azurerm_resource_group.cost_management.name
  automation_account_name = azurerm_automation_account.cost_management.name
  value                   = var.include_forecasting
  description            = "Include cost forecasting data in analysis"
}

resource "azurerm_automation_variable_bool" "include_optimization_recommendations" {
  name                    = "INCLUDE_OPTIMIZATION_RECOMMENDATIONS"
  resource_group_name     = azurerm_resource_group.cost_management.name
  automation_account_name = azurerm_automation_account.cost_management.name
  value                   = var.include_optimization_recommendations
  description            = "Include detailed optimization recommendations from Azure Advisor"
}

# Collection script feature flags (already enhanced)
resource "azurerm_automation_variable_bool" "include_reservations" {
  name                    = "INCLUDE_RESERVATIONS"
  resource_group_name     = azurerm_resource_group.cost_management.name
  automation_account_name = azurerm_automation_account.cost_management.name
  value                   = true
  description            = "Include reserved instance utilization data collection"
}

resource "azurerm_automation_variable_bool" "include_budgets" {
  name                    = "INCLUDE_BUDGETS"
  resource_group_name     = azurerm_resource_group.cost_management.name
  automation_account_name = azurerm_automation_account.cost_management.name
  value                   = true
  description            = "Include budget tracking and alerts"
}

resource "azurerm_automation_variable_bool" "include_advisor" {
  name                    = "INCLUDE_ADVISOR"
  resource_group_name     = azurerm_resource_group.cost_management.name
  automation_account_name = azurerm_automation_account.cost_management.name
  value                   = true
  description            = "Include Azure Advisor recommendations collection"
}

# Note: Azure PowerShell modules are now managed via PowerShell 7.2 Runtime Environment
# with Az PowerShell 11.2.0 and Azure CLI 2.56.0 included by default.
# Additional modules can be installed using the Install-AutomationModules.ps1 script
# which targets the PowerShell 7.2 runtime environment for optimal performance and security.
