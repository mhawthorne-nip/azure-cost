# Azure Cost Management Automation Solution

This comprehensive solution provides automated cost analysis across Azure subscriptions with AI-powered insights, weekly reporting, and AVD resource exclusions. Designed for MVP deployment in East US with the naming convention: `<azure-resource-abbreviation>-nip-costing-dev-eus`.

## 📚 Complete Documentation

- **[📖 Comprehensive Project Documentation](docs/PROJECT_DOCUMENTATION.md)** - Complete technical documentation with architecture, deployment, and operational procedures
- **[🏗️ Architecture Diagrams](docs/ARCHITECTURE_DIAGRAMS.md)** - Visual system architecture and data flow diagrams  
- **[⚡ Quick Reference Guide](docs/QUICK_REFERENCE.md)** - Essential commands and troubleshooting steps

## Key Features

- Single subscription MVP with multi-subscription scalability
- AVD resource exclusion (resources with **VD** in name)
- Azure CLI authentication for testing (no service principal required)
- Low-cost MVP configuration (~$3.53/month)
- Email reporting via Microsoft Graph REST API
- AI-ready architecture (Claude 3.5 Haiku integration)

## 🚀 Quick Start

> **For detailed documentation, see [📖 PROJECT_DOCUMENTATION.md](docs/PROJECT_DOCUMENTATION.md)**

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
Copy-Item "terraform.tfvars.example" "terraform.tfvars"

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

# Test the cost collection runbook
az automation runbook start --resource-group "rg-nip-costing-dev-eus" --automation-account-name "aa-nip-costing-dev-eus" --runbook-name "rb-cost-collection"
```

## 💰 Cost Estimates (East US)

| Resource | Configuration | Monthly Cost |
|----------|--------------|--------------|
| Log Analytics | 1GB/day, 30 days retention | ~$2.50 |
| Automation Account | Basic tier, ~50 jobs/month | Free |
| Storage Account | LRS, Cool tier, <1GB | ~$0.50 |
| Key Vault | Standard, <10K operations | ~$0.03 |
| Data Collection | 1 rule, minimal metrics | ~$0.50 |
| **Total** | | **~$3.53/month** |

*Excludes external costs: Anthropic API calls (~$1-5/month)*

## 🏗️ Architecture

The solution follows a hub-and-spoke model with centralized cost management:

```
Azure Subscriptions → Cost Management APIs → Automation Account → Log Analytics
                                                    ↓
Email Recipients ← Microsoft Graph ← AI Analysis ← Claude 3.5 Haiku
```

**Resource Naming**: All resources follow `<abbreviation>-nip-costing-dev-eus` pattern

## 📊 Monitoring & Operations

### Manual Execution
```powershell
# Run cost collection
az automation runbook start --resource-group "rg-nip-costing-dev-eus" --automation-account-name "aa-nip-costing-dev-eus" --runbook-name "rb-cost-collection"

# Check recent cost data
az monitor log-analytics query --workspace $(terraform output -raw log_analytics_workspace_id) --analytics-query "AzureCostData_CL | where TimeGenerated >= ago(7d) | summarize sum(Cost_d) by ServiceName_s"
```

### Scheduled Operations
- **Daily**: Cost collection at 02:00 EST
- **Weekly**: AI analysis and email reports on Sundays at 06:00 EST

## 🔧 Configuration

### Required Configuration (terraform.tfvars)
```hcl
# Email (Azure AD App Registration with Mail.Send permission)
email_from_address = "costmgmt@yourdomain.com"
email_client_id = "your-app-registration-client-id"
email_tenant_id = "your-tenant-id"
email_client_secret = "your-client-secret"
cost_report_recipients = "admin@domain.com,manager@domain.com"

# AI Analysis
anthropic_api_key = "sk-ant-api03-your-anthropic-key"

# Subscriptions
target_subscription_ids = ["subscription-id-here"]
```

## 🚨 Troubleshooting

**Common Issues:**
- **No cost data**: Check managed identity permissions
- **No emails**: Verify Azure AD app `Mail.Send` permission
- **High costs**: Monitor Log Analytics usage (1GB daily limit)

**Quick Fixes:**
```powershell
# Check permissions
az role assignment list --assignee $(az automation account show --resource-group "rg-nip-costing-dev-eus" --automation-account-name "aa-nip-costing-dev-eus" --query identity.principalId -o tsv)

# View job status
az automation job list --resource-group "rg-nip-costing-dev-eus" --automation-account-name "aa-nip-costing-dev-eus" --output table
```

## 🧹 Cleanup

```powershell
terraform destroy -auto-approve
```

---

📧 **Support**: costmgmt@yourdomain.com  
📅 **Last Updated**: July 24, 2025  
💡 **Version**: MVP 1.0
