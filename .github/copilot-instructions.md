# Azure Cost Management Automation - AI Agent Instructions

## Project Overview
This is an Azure cost management automation solution that collects, analyzes, and reports on multi-subscription Azure costs using PowerShell runbooks, Log Analytics, and AI-powered analysis. The architecture emphasizes cost-efficiency with a ~$3.53/month MVP deployment.

## Core Architecture Patterns

### Naming Convention
All resources follow: `<azure-resource-abbreviation>-nip-costing-dev-eus`
- Resource Group: `rg-nip-costing-dev-eus`  
- Automation Account: `aa-nip-costing-dev-eus`
- Log Analytics: `law-nip-costing-dev-eus`
- Storage: `stnipcostingdev<random>` (due to Azure constraints)

### Data Flow Architecture
1. **Collection**: Daily PowerShell runbooks query Cost Management APIs
2. **Processing**: Filter AVD resources (exclude resources with "VD" in name)
3. **Storage**: Custom Log Analytics table `AzureCostData_CL` with 365-day retention
4. **Analysis**: Weekly AI analysis using Claude 3.5 Haiku via Anthropic API
5. **Reporting**: HTML email reports via Microsoft Graph API

### Authentication Strategy
- **MVP**: Azure CLI authentication for simplicity
- **Production**: Managed Identity with assigned roles: Cost Management Reader, Reader, Billing Reader, Log Analytics Contributor

## Key File Patterns

### Terraform Structure
- `variables.tf`: Contains both infrastructure and application config (email, AI keys)
- `automation.tf`: Defines runbooks, variables, and RBAC assignments
- `log_analytics.tf`: Custom table schema with optimized columns for cost data
- `data_collection.tf`: Performance monitoring for VM rightsizing analysis
- `providers.tf`: Uses Azure CLI auth with specific backend state configuration

### PowerShell Runbook Patterns
- `scripts/CostDataCollection-Automation.ps1`: Daily cost collection with retry logic
- `scripts/WeeklyAnalysisEngine-Automation.ps1`: AI-powered weekly analysis and reporting
- Both use managed identity authentication with `Connect-AzAccount -Identity`
- Automation variables for secure configuration management

### Configuration Management
- `terraform.tfvars.example`: Template showing required variables for email and AI setup
- Sensitive values (API keys, secrets) stored as encrypted automation variables
- Target subscriptions configurable via `TARGET_SUBSCRIPTION_IDS` variable

## Development Workflows

### Local Testing Commands
```powershell
# Deploy infrastructure
terraform init && terraform plan && terraform apply -auto-approve

# Test runbook execution
az automation runbook start --resource-group "rg-nip-costing-dev-eus" --automation-account-name "aa-nip-costing-dev-eus" --runbook-name "rb-cost-collection"

# Query cost data
az monitor log-analytics query --workspace $(terraform output -raw log_analytics_workspace_id) --analytics-query "AzureCostData_CL | take 10"
```

### Debugging Patterns
- Check managed identity permissions: `az role assignment list --assignee <principal-id>`
- View automation variables: `az automation variable list --resource-group <rg> --automation-account-name <aa>`
- Monitor runbook jobs: `az automation job list --resource-group <rg> --automation-account-name <aa>`

### Cleanup Requirements
- **Always clean up temporary files**: Remove all test files, debug scripts, and temporary artifacts created during development and troubleshooting
- **Common temporary file patterns to remove**:
  - `test-*.ps1` files in the scripts directory
  - `debug-*.ps1` or `*-debug.ps1` files
  - Log files like `*.log`, `*-debug.log`
  - Temporary configuration files ending in `-temp`, `-test`, or `-backup`
- **Preserve only production files**: Keep only the core production scripts and configuration files
- **Document cleanup**: When completing work, confirm all temporary files have been removed from the repository

## Integration Points

### External Dependencies
- **Anthropic API**: Claude 3.5 Haiku for cost analysis and recommendations
- **Microsoft Graph**: Email delivery using Azure AD app registration
- **Azure Cost Management API**: Source of cost data across subscriptions
- **Azure CLI**: Primary authentication method for MVP

### Data Schema
Custom Log Analytics table `AzureCostData_CL` with key columns:
- `Cost_d` (real), `ServiceName_s` (string), `IsAVDResource_b` (boolean)
- `MeterCategory_s` (string), `CollectionDate_s` (string)
- `ResourceName_s` (string), `Location_s` (string), `Currency_s` (string)
- Optimized for cost queries and AVD resource filtering

### Additional Tables
- `AzureCostBaseline_CL`: Baseline calculations and trend analysis
- `AzureHistoricalCostData_CL`: Long-term cost history and comparisons  
- `AzureInvoiceData_CL`: **DEPRECATED (July 2025)** - Invoice collection discontinued due to API rate limiting issues and lack of useful data for pay-as-you-go subscriptions. Contains 11 legacy records, will auto-expire after 365-day retention period.

### Email Configuration Requirements
- Azure AD App Registration with `Mail.Send` application permission
- Variables: `email_from_address`, `email_client_id`, `email_tenant_id`, `email_client_secret`
- Recipients configured via `cost_report_recipients` comma-separated list

## Cost Optimization Patterns
- Log Analytics daily quota limited to 1GB for MVP
- Basic SKU Automation Account
- Performance counter sampling every 5 minutes (not 1 minute)
- ZRS storage replication for data resilience with cost balance
- 30-day log retention (minimum) vs 365-day cost data retention

## Azure-Specific Rules

### Use Azure Tools & MCP Services
When handling requests related to Azure, **always prioritize using Azure tools and MCP services** over manual commands or generic approaches.

#### Essential Azure MCP Services for This Project
- **cosmos**: Query Cosmos DB resources and data (if used for cost storage)
- **kusto**: Query Azure Data Explorer/Kusto clusters for analytics
- **monitor**: Query Log Analytics workspace, metrics, and Azure Monitor data
- **storage**: Manage Azure Storage accounts, containers, and blobs
- **role**: Check RBAC assignments and permissions for managed identities

#### Azure Tool Usage Patterns
- Use `azure_resources-query_azure_resource_graph` for discovering and querying Azure resources
- Use `azure_cli-generate_azure_cli_command` for generating proper Azure CLI commands
- Use `mcp_azure_mcp_ser_monitor_workspace_log_query` for querying Log Analytics data
- Use `mcp_azure_mcp_ser_storage_*` tools for storage operations instead of manual Azure CLI

### Use Azure Code Gen Best Practices
When generating code for Azure, running terminal commands for Azure, or performing operations related to Azure, invoke your `azure_development-get_code_gen_best_practices` tool if available.

### Use Azure Deployment Best Practices  
When deploying to Azure or preparing applications for deployment to Azure, invoke your `azure_development-get_deployment_best_practices` tool if available.

### Cost Management Specific MCP Usage
- **Log Analytics Queries**: Use `mcp_azure_mcp_ser_monitor_workspace_log_query` to query the `AzureCostData_CL` table
- **Resource Discovery**: Use `azure_resources-query_azure_resource_graph` to find cost-related resources
- **Storage Operations**: Use `mcp_azure_mcp_ser_storage_*` tools for managing cost reports and data files
- **Role Verification**: Use `mcp_azure_mcp_ser_role_assignment_list` to verify automation account permissions

### Table-Specific Query Patterns
- **Current Costs**: Query `AzureCostData_CL` for daily cost collection data
- **Baseline Analysis**: Query `AzureCostBaseline_CL` for trend calculations
- **Historical Trends**: Query `AzureHistoricalCostData_CL` for long-term analysis
- **Performance Data**: Query `Perf` table for VM rightsizing recommendations

### PowerShell Runbook Best Practices
- Always use managed identity authentication: `Connect-AzAccount -Identity`
- Implement retry logic for Azure API calls (see existing patterns)
- Use automation variables for configuration, encrypted for sensitive data
- Include comprehensive error handling and logging for debugging

### Example MCP Integration Patterns
```powershell
# Query current cost data
# Use MCP: mcp_azure_mcp_ser_monitor_workspace_log_query with AzureCostData_CL

# Query baseline trends  
# Use MCP: mcp_azure_mcp_ser_monitor_workspace_log_query with AzureCostBaseline_CL

# Instead of: az storage blob list
# Use MCP: mcp_azure_mcp_ser_storage_blob_list

# Instead of: az role assignment list
# Use MCP: mcp_azure_mcp_ser_role_assignment_list
```