# Azure Cost Management Automation Solution

This comprehensive solution provides automated cost analysis across Azure subscriptions with AI-powered insights, weekly reporting, and AVD resource exclusions. Designed for MVP deployment in East US with the naming convention: `<azure-resource-abbreviation>-nip-costing-dev-eus`.

## Key Features

- Single subscription MVP with multi-subscription scalability
- AVD resource exclusion (resources with **VD** in name)
- Azure CLI authentication for testing (no service principal required)
- Low-cost MVP configuration (~$3.53/month)
- Email reporting via Microsoft Graph REST API
- AI-ready architecture (Claude 3.5 Haiku integration)

## Quick Start

### Prerequisites

1. **Azure CLI** installed and configured
2. **Terraform** installed (>= 1.3)
3. **Azure AD App Registration** for email notifications
4. **Anthropic API key** for AI analysis

### Step 1: Setup Azure Authentication

```powershell
# Login to Azure
az login

# Set the target subscription
az account set --subscription "e653ba88-fc91-42f4-b22b-c35e36b00835"

# Verify current subscription
az account show --output table
```

### Step 2: Configure Variables

```powershell
# Copy the example variables file
cp terraform.tfvars.example terraform.tfvars

# Edit terraform.tfvars with your actual values:
# - Email configuration (Azure AD app details)
# - Anthropic API key
# - Email recipients
```

### Step 3: Deploy Infrastructure

```powershell
# Initialize Terraform
terraform init

# Review the deployment plan
terraform plan

# Deploy the infrastructure
terraform apply -auto-approve
```

### Step 4: Verify Deployment

```powershell
# Check resource group
az group show --name "rg-nip-costing-dev-eus" --output table

# Verify automation account
az automation account show --resource-group "rg-nip-costing-dev-eus" --automation-account-name "aa-nip-costing-dev-eus"

# Test the cost collection runbook
az automation runbook start --resource-group "rg-nip-costing-dev-eus" --automation-account-name "aa-nip-costing-dev-eus" --runbook-name "rb-cost-collection"
```

## Resource Naming Convention

All resources follow the pattern: `<abbreviation>-nip-costing-dev-eus`

- Resource Group: `rg-nip-costing-dev-eus`
- Log Analytics: `law-nip-costing-dev-eus`
- Automation Account: `aa-nip-costing-dev-eus`
- Storage Account: `stnipcostingdev<random>` (due to Azure naming restrictions)
- Key Vault: `kv-dev-cost-<random>`

## Architecture Overview

### Core Components

1. **Log Analytics Workspace**: Stores cost data with custom table
2. **Azure Automation**: Executes PowerShell runbooks on schedule
3. **Storage Account**: Stores reports and temporary data
4. **Key Vault**: Secures sensitive configuration
5. **Data Collection Rules**: Configures monitoring and metrics

### Data Flow

1. **Daily Collection**: Automation runbook queries Cost Management API
2. **Data Processing**: Filters AVD resources and formats data
3. **Storage**: Sends processed data to Log Analytics
4. **Weekly Analysis**: AI-powered analysis using Claude 3.5 Haiku
5. **Reporting**: HTML email reports via Microsoft Graph

## Configuration

### Email Setup (Azure AD App Registration)

1. Create Azure AD App Registration:
   - Name: `app-nip-costing-email-dev`
   - Permissions: `Mail.Send` (Application permission)
   - Create client secret

2. Update `terraform.tfvars`:
   ```hcl
   email_from_address = "costmgmt@yourdomain.com"
   email_client_id = "your-app-client-id"
   email_tenant_id = "your-tenant-id"
   email_client_secret = "your-client-secret"
   ```

### AI Analysis Setup

1. Get Anthropic API key from https://console.anthropic.com
2. Update `terraform.tfvars`:
   ```hcl
   anthropic_api_key = "sk-ant-api03-your-key-here"
   ```

## Operational Guide

### Manual Execution

```powershell
# Run cost collection manually
az automation runbook start --resource-group "rg-nip-costing-dev-eus" --automation-account-name "aa-nip-costing-dev-eus" --runbook-name "rb-cost-collection"

# Run weekly analysis manually
az automation runbook start --resource-group "rg-nip-costing-dev-eus" --automation-account-name "aa-nip-costing-dev-eus" --runbook-name "rb-weekly-analysis"

# Check job status
az automation job list --resource-group "rg-nip-costing-dev-eus" --automation-account-name "aa-nip-costing-dev-eus" --output table
```

### Monitoring

Query Log Analytics for cost data:
```kql
AzureCostData_CL
| where TimeGenerated >= ago(7d)
| summarize TotalCost = sum(Cost_d) by ServiceName_s
| order by TotalCost desc
```

### Scheduled Execution

- **Daily**: Cost collection at 2:00 AM EST
- **Weekly**: Analysis and reporting on Sundays at 6:00 AM EST

## Cost Estimates (East US)

| Resource | Configuration | Monthly Cost |
|----------|--------------|--------------|
| Log Analytics | 1GB/day, 30 days retention | ~$2.50 |
| Automation Account | Basic tier, ~50 jobs/month | Free |
| Storage Account | LRS, Cool tier, <1GB | ~$0.50 |
| Key Vault | Standard, <10K operations | ~$0.03 |
| Data Collection | 1 rule, minimal metrics | ~$0.50 |
| **Total** | | **~$3.53/month** |

*Excludes external costs: Anthropic API calls (~$1-5/month)*

## Scaling to Production

### Add Multiple Subscriptions

Update `terraform.tfvars`:
```hcl
target_subscription_ids = [
  "e653ba88-fc91-42f4-b22b-c35e36b00835",
  "subscription-id-2",
  "subscription-id-3"
]
```

### Service Principal Authentication

For production, replace Azure CLI auth:

1. Create service principal:
   ```powershell
   az ad sp create-for-rbac --name "sp-nip-costing-terraform-prod" --scopes "/subscriptions/e653ba88-fc91-42f4-b22b-c35e36b00835"
   ```

2. Update `providers.tf`:
   ```hcl
   provider "azurerm" {
     features {}
     client_id       = var.client_id
     client_secret   = var.client_secret
     tenant_id       = var.tenant_id
     subscription_id = var.management_subscription_id
   }
   ```

### Enhanced Security

1. Enable Key Vault purge protection
2. Increase Log Analytics retention
3. Add network restrictions
4. Enable backup for critical data

## Troubleshooting

### Common Issues

1. **Authentication Errors**:
   ```powershell
   # Re-login to Azure
   az logout
   az login
   ```

2. **Runbook Failures**:
   - Check managed identity permissions
   - Verify automation variables are set
   - Review runbook logs in Azure portal

3. **No Email Delivery**:
   - Verify Azure AD app permissions
   - Check client secret expiration
   - Confirm from address is valid

4. **Missing Cost Data**:
   - Ensure Cost Management APIs are enabled
   - Check date ranges in queries
   - Verify subscription access

### Debug Commands

```powershell
# Check role assignments
az role assignment list --assignee $(az automation account show --resource-group "rg-nip-costing-dev-eus" --automation-account-name "aa-nip-costing-dev-eus" --query identity.principalId -o tsv) --output table

# View automation variables
az automation variable list --resource-group "rg-nip-costing-dev-eus" --automation-account-name "aa-nip-costing-dev-eus" --output table

# Check Log Analytics data
az monitor log-analytics query --workspace $(terraform output -raw log_analytics_workspace_id) --analytics-query "AzureCostData_CL | take 10"
```

## Cleanup

To remove all resources:

```powershell
terraform destroy -auto-approve
```

## Support

For issues or questions:
1. Check Azure Automation job logs
2. Review Log Analytics for data issues
3. Verify email and AI configuration
4. Contact the DevOps team

---

**Version**: MVP 1.0  
**Last Updated**: $(Get-Date -Format 'yyyy-MM-dd')  
**Estimated Monthly Cost**: $3.53 + API usage
