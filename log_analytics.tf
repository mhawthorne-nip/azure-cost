resource "azurerm_resource_group" "cost_management" {
  name     = "rg-${var.project_name}-${var.environment}-${var.location_abbreviation}"
  location = var.location
  tags     = local.common_tags
}

resource "azurerm_log_analytics_workspace" "cost_management" {
  name                = "law-${var.project_name}-${var.environment}-${var.location_abbreviation}"
  location            = azurerm_resource_group.cost_management.location
  resource_group_name = azurerm_resource_group.cost_management.name
  sku                 = "PerGB2018"
  retention_in_days   = var.enable_extended_retention ? 90 : var.log_retention_days
  daily_quota_gb      = 1 # Reduced from 50GB to 1GB for MVP cost savings

  tags = merge(local.common_tags, {
    Purpose = "CostManagement"
    Backup  = "NotRequired" # No backup for MVP
    RetentionStrategy = var.enable_extended_retention ? "Extended" : "Basic"
  })
}

# Custom Log Analytics tables are auto-created by data ingestion
# They cannot be managed via DataCollectionRuleBased API for "Classic" tables
# 
# ACTIVE TABLES (automatically created when PowerShell scripts send data with Log-Type headers):
# - AzureCostData_CL (from CostDataCollection-Automation.ps1) - Primary cost data
# - AzureCostBaseline_CL (from WeeklyAnalysisEngine-Automation.ps1) - Baseline calculations and trends
# - AzureHistoricalCostData_CL (from various analysis scripts) - Long-term historical data
# - AzureCostAnalysisSummary_CL (from WeeklyAnalysisEngine-Automation.ps1) - Enhanced analysis summaries
# - AzureForecastData_CL (from CostDataCollection-Automation.ps1) - Cost forecasting data
# - AzureReservationData_CL (from CostDataCollection-Automation.ps1) - Reserved instance utilization
# - AzureBudgetData_CL (from CostDataCollection-Automation.ps1) - Budget tracking and alerts
# - AzureAdvisorData_CL (from CostDataCollection-Automation.ps1) - Azure Advisor recommendations
# 
# DEPRECATED TABLES (no longer receiving data, will auto-expire after 365 days):
# - AzureInvoiceData_CL (REMOVED July 2025 - invoice collection discontinued due to API limitations)
#   Contains 11 legacy records, will automatically disappear after retention period expires
# 
# All active tables maintain 365-day retention and schemas are automatically managed by PowerShell scripts
# Enhanced tables support the new v2.0 analysis engine with Chain-of-Thought AI and multi-dimensional analytics
