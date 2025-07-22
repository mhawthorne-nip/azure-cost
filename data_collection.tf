resource "azurerm_monitor_data_collection_endpoint" "cost_management" {
  name                = "dce-${var.environment}-cost-mgmt"
  resource_group_name = azurerm_resource_group.cost_management.name
  location            = azurerm_resource_group.cost_management.location
  kind                = "Windows"
  tags                = local.common_tags
}

resource "azurerm_monitor_data_collection_rule" "cost_metrics" {
  name                        = "dcr-${var.environment}-cost-metrics"
  resource_group_name         = azurerm_resource_group.cost_management.name
  location                    = azurerm_resource_group.cost_management.location
  data_collection_endpoint_id = azurerm_monitor_data_collection_endpoint.cost_management.id
  description                 = "Data collection rule for VM rightsizing analysis and cost optimization"

  destinations {
    log_analytics {
      workspace_resource_id = azurerm_log_analytics_workspace.cost_management.id
      name                  = "destination-log-analytics"
    }
  }

  data_flow {
    streams      = ["Microsoft-Perf", "Microsoft-Event"]
    destinations = ["destination-log-analytics"]
  }

  data_sources {
    performance_counter {
      streams                       = ["Microsoft-Perf"]
      sampling_frequency_in_seconds = 300 # 5 minutes for cost efficiency while maintaining accuracy
      counter_specifiers = [
        # CPU utilization metrics
        "\\Processor(_Total)\\% Processor Time",
        "\\Processor Information(_Total)\\% Processor Utility",

        # Memory utilization metrics
        "\\Memory\\Available Bytes",
        "\\Memory\\% Committed Bytes In Use",
        "\\Memory\\Committed Bytes",

        # Disk performance metrics
        "\\LogicalDisk(_Total)\\% Disk Time",
        "\\LogicalDisk(_Total)\\Disk Bytes/sec",
        "\\LogicalDisk(_Total)\\% Free Space",

        # Network utilization metrics
        "\\Network Interface(*)\\Bytes Total/sec",
        "\\Network Interface(*)\\Packets/sec"
      ]
      name = "perfCounterDataSource"
    }

    windows_event_log {
      streams = ["Microsoft-Event"]
      x_path_queries = [
        # Focus on critical errors and warnings only for efficiency
        "System!*[System[(Level=1 or Level=2)]]"
      ]
      name = "eventDataSource"
    }
  }

  tags = merge(local.common_tags, {
    Purpose   = "VM Rightsizing Analysis"
    Component = "Data Collection"
  })
}
