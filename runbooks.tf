# Azure Automation Runbooks and Schedules
# This file defines the runbooks and schedules for the cost management automation

# Cost Data Collection Runbook
resource "azurerm_automation_runbook" "cost_collection" {
  name                    = "rb-cost-collection"
  location                = azurerm_resource_group.cost_management.location
  resource_group_name     = azurerm_resource_group.cost_management.name
  automation_account_name = azurerm_automation_account.cost_management.name
  log_verbose             = false
  log_progress            = false
  description             = "Daily cost data collection from Azure Cost Management API"
  runbook_type            = "PowerShell72"

  content = file("${path.module}/scripts/CostDataCollection-Automation.ps1")

  tags = local.common_tags
}

# Weekly Analysis Runbook
resource "azurerm_automation_runbook" "weekly_analysis" {
  name                    = "rb-weekly-analysis"
  location                = azurerm_resource_group.cost_management.location
  resource_group_name     = azurerm_resource_group.cost_management.name
  automation_account_name = azurerm_automation_account.cost_management.name
  log_verbose             = false
  log_progress            = false
  description             = "Weekly cost analysis and reporting"
  runbook_type            = "PowerShell72"

  content = file("${path.module}/scripts/WeeklyAnalysisEngine-Automation.ps1")

  tags = local.common_tags
}

# Invoice Collection Runbook - REMOVED
# Invoice data collection was removed due to API rate limiting issues
# and lack of useful data for pay-as-you-go subscriptions

# Daily Cost Collection Schedule
resource "azurerm_automation_schedule" "daily_collection" {
  name                    = "sch-daily-cost-collection"
  resource_group_name     = azurerm_resource_group.cost_management.name
  automation_account_name = azurerm_automation_account.cost_management.name
  frequency               = "Day"
  interval                = 1
  timezone                = "America/New_York"
  start_time              = "2025-07-23T03:00:00-04:00"
  description             = "Daily cost data collection"
  expiry_time             = "9999-12-31T18:59:00-05:00"
}

# Weekly Analysis Schedule
resource "azurerm_automation_schedule" "weekly_analysis" {
  name                    = "sch-weekly-analysis"
  resource_group_name     = azurerm_resource_group.cost_management.name
  automation_account_name = azurerm_automation_account.cost_management.name
  frequency               = "Week"
  interval                = 1
  timezone                = "America/New_York"
  start_time              = "2025-07-28T07:00:00-04:00"
  description             = "Weekly cost analysis and reporting"
  expiry_time             = "9999-12-31T18:59:00-05:00"
  week_days               = ["Sunday"]
}

# Monthly Invoice Collection Schedule - REMOVED
# Invoice collection schedule was removed along with the runbook

# Schedule Job Associations
resource "azurerm_automation_job_schedule" "daily_collection" {
  resource_group_name     = azurerm_resource_group.cost_management.name
  automation_account_name = azurerm_automation_account.cost_management.name
  schedule_name           = azurerm_automation_schedule.daily_collection.name
  runbook_name            = azurerm_automation_runbook.cost_collection.name
}

resource "azurerm_automation_job_schedule" "weekly_analysis" {
  resource_group_name     = azurerm_resource_group.cost_management.name
  automation_account_name = azurerm_automation_account.cost_management.name
  schedule_name           = azurerm_automation_schedule.weekly_analysis.name
  runbook_name            = azurerm_automation_runbook.weekly_analysis.name
}

# Monthly invoice collection job schedule - REMOVED
