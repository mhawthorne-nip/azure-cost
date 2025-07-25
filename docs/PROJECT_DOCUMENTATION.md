# Azure Cost Management Automation - Project Documentation

## Table of Contents
1. [Project Overview](#project-overview)
2. [Architecture](#architecture)
3. [Infrastructure Components](#infrastructure-components)
4. [Data Flow](#data-flow)
5. [Configuration](#configuration)
6. [Deployment Guide](#deployment-guide)
7. [Operational Procedures](#operational-procedures)
8. [Monitoring & Troubleshooting](#monitoring--troubleshooting)
9. [Security Considerations](#security-considerations)
10. [Cost Analysis](#cost-analysis)
11. [Scaling Strategy](#scaling-strategy)
12. [API Reference](#api-reference)

## Project Overview

### Purpose
The Azure Cost Management Automation solution provides automated cost analysis across Azure subscriptions with AI-powered insights, weekly reporting, and AVD (Azure Virtual Desktop) resource exclusions. It's designed as a low-cost MVP solution (~$3.53/month) that can scale to enterprise requirements.

### Key Features
- **Multi-subscription cost tracking** with single subscription MVP starting point
- **AVD resource filtering** - Excludes resources containing "VD" in their names
- **AI-powered analysis** using Claude 3.5 Haiku for intelligent cost insights
- **Automated email reporting** via Microsoft Graph API integration
- **Comprehensive data retention** with 365-day cost data history
- **Azure CLI authentication** for simplified MVP deployment
- **Scheduled automation** with daily collection and weekly analysis

### Business Value
- **Cost Transparency**: Centralized visibility across multiple Azure subscriptions
- **Proactive Management**: Early detection of cost anomalies and trends
- **Resource Optimization**: AI-driven recommendations for cost reduction
- **Compliance**: Automated reporting for financial governance
- **Scalability**: MVP-to-enterprise deployment path

## Architecture

### High-Level Architecture Diagram
```
┌─────────────────┐    ┌──────────────────┐    ┌─────────────────┐
│ Azure           │    │ Cost Management  │    │ Log Analytics   │
│ Subscriptions   │───▶│ APIs             │───▶│ Workspace       │
│ (1-N)          │    │                  │    │                 │
└─────────────────┘    └──────────────────┘    └─────────────────┘
                                                         │
┌─────────────────┐    ┌──────────────────┐             │
│ Email           │◀───│ Automation       │◀────────────┘
│ Recipients      │    │ Account          │
│                 │    │ (PowerShell)     │
└─────────────────┘    └──────────────────┘
                                │
                       ┌──────────────────┐
                       │ Claude 3.5       │
                       │ Haiku API        │
                       │ (Anthropic)      │
                       └──────────────────┘
```

### Component Interaction Flow
```
Daily Schedule (02:00 EST)
├── Automation Account triggers Cost Collection Runbook
├── PowerShell script authenticates with Managed Identity
├── Queries Cost Management API for each subscription
├── Filters out AVD resources (name contains "VD")
├── Transforms and validates cost data
└── Ingests data into Log Analytics custom table

Weekly Schedule (Sunday 06:00 EST)
├── Automation Account triggers Analysis Engine Runbook
├── PowerShell script queries aggregated cost data
├── Sends data to Claude 3.5 Haiku for AI analysis
├── Generates HTML email report with insights
└── Sends email via Microsoft Graph API
```

### Resource Naming Convention
All resources follow the pattern: `<azure-resource-abbreviation>-nip-costing-dev-eus`

| Resource Type | Naming Pattern | Example |
|---------------|----------------|---------|
| Resource Group | `rg-{project}-{env}-{location}` | `rg-nip-costing-dev-eus` |
| Automation Account | `aa-{project}-{env}-{location}` | `aa-nip-costing-dev-eus` |
| Log Analytics | `law-{project}-{env}-{location}` | `law-nip-costing-dev-eus` |
| Storage Account | `st{project}{env}{random}` | `stnipcostingdev4a7b` |
| Key Vault | `kv-{env}-cost-{random}` | `kv-dev-cost-8f9e` |

## Infrastructure Components

### Core Azure Resources

#### 1. Log Analytics Workspace (`law-nip-costing-dev-eus`)
- **Purpose**: Central repository for cost data and operational logs
- **Retention**: 30 days for operational logs, 365 days for cost data
- **Daily Quota**: 1GB limit for cost optimization
- **Custom Tables**:
  - `AzureCostData_CL`: Primary cost collection data
  - `AzureCostBaseline_CL`: Baseline calculations and trends
  - `AzureHistoricalCostData_CL`: Long-term historical analysis
  - `AzureInvoiceData_CL`: **DEPRECATED** (auto-expires July 2026)

#### 2. Azure Automation Account (`aa-nip-costing-dev-eus`)
- **SKU**: Basic (Free tier)
- **PowerShell Version**: 7.4
- **Az Module Version**: 12.3.0
- **Managed Identity**: System-assigned with Cost Management Reader permissions
- **Runbooks**:
  - `rb-cost-collection`: Daily cost data collection
  - `rb-weekly-analysis`: Weekly AI analysis and reporting
  - `rb-baseline-calculation`: Baseline trend calculations

#### 3. Storage Account (`stnipcostingdev<random>`)
- **Replication**: Zone-Redundant Storage (ZRS)
- **Access Tier**: Cool for cost optimization
- **Purpose**: Temporary file storage, report staging
- **Containers**: Automatically created for runbook operations

#### 4. Key Vault (`kv-dev-cost-<random>`)
- **SKU**: Standard
- **Access Policy**: Automation Account managed identity
- **Secrets**: Anthropic API key, email client secret
- **Purpose**: Secure configuration storage

#### 5. Data Collection Rules
- **VM Performance Monitoring**: CPU, Memory, Disk metrics every 5 minutes
- **Purpose**: VM rightsizing recommendations
- **Target**: All Windows and Linux VMs in monitored subscriptions

### Custom Log Analytics Tables Schema

#### AzureCostData_CL
```sql
| Column | Type | Description |
|--------|------|-------------|
| TimeGenerated | datetime | Record timestamp |
| Cost_d | real | Cost amount in USD |
| Currency_s | string | Currency code |
| ServiceName_s | string | Azure service name |
| ResourceName_s | string | Resource name |
| ResourceGroupName_s | string | Resource group |
| SubscriptionId_s | string | Subscription GUID |
| SubscriptionName_s | string | Subscription display name |
| MeterCategory_s | string | Billing meter category |
| MeterSubCategory_s | string | Billing meter subcategory |
| MeterName_s | string | Billing meter name |
| Location_s | string | Azure region |
| IsAVDResource_b | bool | True if resource name contains "VD" |
| CollectionDate_s | string | Data collection date |
| UsageDate_s | string | Original usage date |
| Department_s | string | Cost center/department |
| Tags_s | string | JSON-encoded resource tags |
```

## Data Flow

### Daily Cost Collection Process

```mermaid
graph TD
    A[Scheduled Trigger 02:00 EST] --> B[Authenticate with Managed Identity]
    B --> C[Get Target Subscriptions from Automation Variables]
    C --> D[For Each Subscription]
    D --> E[Query Cost Management API]
    E --> F[Parse and Validate Response]
    F --> G[Filter AVD Resources]
    G --> H[Transform Data Format]
    H --> I[Send to Log Analytics]
    I --> J[Update Collection Metrics]
    J --> K[Log Completion Status]
```

### Weekly Analysis Engine Process

```mermaid
graph TD
    A[Scheduled Trigger Sunday 06:00 EST] --> B[Query Cost Data from Log Analytics]
    B --> C[Aggregate by Service, Subscription, Trends]
    C --> D[Prepare AI Analysis Prompt]
    D --> E[Send to Claude 3.5 Haiku API]
    E --> F[Process AI Response]
    F --> G[Generate HTML Email Template]
    G --> H[Authenticate with Microsoft Graph]
    H --> I[Send Email to Recipients]
    I --> J[Log Analysis Completion]
```

### Data Retention Strategy

| Data Type | Retention Period | Storage Location | Purpose |
|-----------|------------------|------------------|---------|
| Cost Data | 365 days | Log Analytics | Trend analysis, reporting |
| Operational Logs | 30 days | Log Analytics | Troubleshooting, monitoring |
| VM Performance | 90 days | Log Analytics | Rightsizing recommendations |
| Email Reports | 7 days | Storage Account | Recent report access |
| Baseline Calculations | 365 days | Log Analytics | Trend baselines |

## Configuration

### Required Environment Variables

#### Email Configuration (Azure AD App Registration)
```terraform
email_from_address = "costmgmt@yourdomain.com"
email_client_id = "12345678-1234-1234-1234-123456789012"
email_tenant_id = "87654321-4321-4321-4321-210987654321"
email_client_secret = "your-secret-value"
cost_report_recipients = "admin@domain.com,manager@domain.com"
```

#### AI Configuration
```terraform
anthropic_api_key = "sk-ant-api03-your-anthropic-key-here"
```

#### Subscription Management
```terraform
management_subscription_id = "e653ba88-fc91-42f4-b22b-c35e36b00835"
target_subscription_ids = [
  "e653ba88-fc91-42f4-b22b-c35e36b00835",
  "additional-subscription-id-here"
]
```

### Azure AD App Registration Setup

1. **Create App Registration**:
   ```powershell
   az ad app create --display-name "app-nip-costing-email-dev"
   ```

2. **Configure API Permissions**:
   - Microsoft Graph: `Mail.Send` (Application permission)
   - Admin consent required

3. **Create Client Secret**:
   ```powershell
   az ad app credential reset --id <app-id> --display-name "CostManagement"
   ```

### Feature Flags Configuration

```terraform
# Advanced AI Analysis Features
enable_advanced_prompting = true           # Chain-of-thought analysis
include_anomaly_detection = true           # Statistical anomaly detection
include_chargeback_analysis = true         # Tag compliance analysis
include_forecasting = true                 # Cost forecasting
include_optimization_recommendations = true # Azure Advisor integration
```

## Deployment Guide

### Prerequisites Checklist

- [ ] Azure CLI installed and configured
- [ ] Terraform >= 1.3 installed
- [ ] Azure subscription with appropriate permissions
- [ ] Azure AD App Registration created for email
- [ ] Anthropic API key obtained

### Step-by-Step Deployment

#### 1. Environment Setup
```powershell
# Clone repository
git clone <repository-url>
cd azure-cost

# Authenticate with Azure
az login
az account set --subscription "e653ba88-fc91-42f4-b22b-c35e36b00835"
az account show --output table
```

#### 2. Configuration
```powershell
# Copy configuration template
Copy-Item "terraform.tfvars.example" "terraform.tfvars"

# Edit terraform.tfvars with your values
notepad terraform.tfvars
```

#### 3. Infrastructure Deployment
```powershell
# Initialize Terraform
terraform init

# Review deployment plan
terraform plan -out=tfplan

# Deploy infrastructure
terraform apply tfplan
```

#### 4. Verification
```powershell
# Check resource deployment
terraform output

# Verify automation account
$resourceGroup = terraform output -raw resource_group_name
$automationAccount = terraform output -raw automation_account_name

az automation account show --resource-group $resourceGroup --automation-account-name $automationAccount
```

#### 5. Test Execution
```powershell
# Manual runbook execution
az automation runbook start --resource-group $resourceGroup --automation-account-name $automationAccount --name "rb-cost-collection"

# Monitor job status
az automation job list --resource-group $resourceGroup --automation-account-name $automationAccount --output table
```

### Post-Deployment Configuration

#### Verify Scheduled Jobs
```powershell
az automation schedule list --resource-group $resourceGroup --automation-account-name $automationAccount --output table
```

#### Test Email Functionality
```powershell
# Trigger weekly analysis manually
az automation runbook start --resource-group $resourceGroup --automation-account-name $automationAccount --name "rb-weekly-analysis"
```

## Operational Procedures

### Daily Operations

#### Monitor Cost Collection
```kql
// Query recent cost data collection
AzureCostData_CL
| where TimeGenerated >= ago(2d)
| summarize 
    TotalRecords = count(),
    TotalCost = sum(Cost_d),
    UniqueSubscriptions = dcount(SubscriptionId_s),
    UniqueServices = dcount(ServiceName_s)
by bin(TimeGenerated, 1d)
| order by TimeGenerated desc
```

#### Check Collection Status
```powershell
# View recent automation jobs
az automation job list --resource-group "rg-nip-costing-dev-eus" --automation-account-name "aa-nip-costing-dev-eus" --query "[?startTime>='2025-01-01'].{name:name, status:status, startTime:startTime}" --output table
```

### Weekly Operations

#### Validate Email Reports
```kql
// Check weekly analysis execution
AzureCostData_CL
| where TimeGenerated >= ago(8d)
| summarize WeeklyCost = sum(Cost_d) by SubscriptionName_s
| order by WeeklyCost desc
```

#### Review AI Analysis Quality
- Check email report content for accuracy
- Validate cost anomaly detection
- Review optimization recommendations

### Monthly Operations

#### Cost Trend Analysis
```kql
// Monthly cost trends by service
AzureCostData_CL
| where TimeGenerated >= ago(90d)
| extend Month = format_datetime(TimeGenerated, 'yyyy-MM')
| summarize MonthlyCost = sum(Cost_d) by Month, ServiceName_s
| evaluate pivot(Month, sum(MonthlyCost))
```

#### Performance Review
- Review Log Analytics usage against 1GB daily quota
- Analyze automation account job execution metrics
- Validate managed identity permissions

### Manual Runbook Execution

#### Cost Collection
```powershell
# Start cost collection runbook
$jobId = az automation runbook start --resource-group "rg-nip-costing-dev-eus" --automation-account-name "aa-nip-costing-dev-eus" --name "rb-cost-collection" --query "name" -o tsv

# Monitor job progress
while ((az automation job show --automation-account-name "aa-nip-costing-dev-eus" --resource-group "rg-nip-costing-dev-eus" --name $jobId --query "status" -o tsv) -eq "Running") {
    Write-Host "Job still running..."
    Start-Sleep 30
}

# Get final status
az automation job show --automation-account-name "aa-nip-costing-dev-eus" --resource-group "rg-nip-costing-dev-eus" --name $jobId --query "{status:status, startTime:startTime, endTime:endTime}" -o table
```

#### Weekly Analysis
```powershell
# Start weekly analysis runbook
az automation runbook start --resource-group "rg-nip-costing-dev-eus" --automation-account-name "aa-nip-costing-dev-eus" --name "rb-weekly-analysis"
```

## Monitoring & Troubleshooting

### Key Metrics to Monitor

#### System Health Metrics
- Automation job success rate
- Log Analytics data ingestion rate
- API call success rate (Cost Management, Anthropic, Graph)
- Email delivery success rate

#### Cost Data Quality Metrics
- Daily record count consistency
- Data completeness (no missing subscriptions)
- AVD filtering accuracy
- Cost value validation (no negative/null costs)

### Common Issues and Solutions

#### 1. Authentication Failures
**Symptoms**: Runbooks fail with authentication errors
**Solutions**:
```powershell
# Verify managed identity permissions
$principalId = az automation account show --resource-group "rg-nip-costing-dev-eus" --automation-account-name "aa-nip-costing-dev-eus" --query "identity.principalId" -o tsv

az role assignment list --assignee $principalId --output table

# Re-assign missing roles if needed
az role assignment create --assignee $principalId --role "Cost Management Reader" --scope "/subscriptions/e653ba88-fc91-42f4-b22b-c35e36b00835"
```

#### 2. No Cost Data Collection
**Symptoms**: Empty or missing cost data in Log Analytics
**Diagnostics**:
```kql
// Check data ingestion
AzureCostData_CL
| where TimeGenerated >= ago(7d)
| summarize count() by bin(TimeGenerated, 1d)
| order by TimeGenerated desc
```

**Solutions**:
- Verify Cost Management API permissions
- Check subscription IDs in automation variables
- Review runbook execution logs

#### 3. Email Delivery Failures
**Symptoms**: Weekly reports not received
**Diagnostics**:
```powershell
# Check automation variables
az automation variable list --resource-group "rg-nip-costing-dev-eus" --automation-account-name "aa-nip-costing-dev-eus" --query "[?name contains 'email']" --output table
```

**Solutions**:
- Verify Azure AD app permissions
- Check client secret expiration
- Validate recipient email addresses

#### 4. High Log Analytics Costs
**Symptoms**: Exceeding 1GB daily quota
**Diagnostics**:
```kql
// Check data ingestion by table
Usage
| where TimeGenerated >= ago(7d)
| summarize TotalGB = sum(Quantity) / 1000 by DataType
| order by TotalGB desc
```

**Solutions**:
- Adjust data collection frequency
- Review data retention policies
- Optimize query efficiency

### Debugging Tools

#### Log Analytics Queries
```kql
// Failed runbook executions
AzureDiagnostics
| where ResourceProvider == "MICROSOFT.AUTOMATION"
| where Category == "JobLogs"
| where ResultDescription contains "Failed"
| order by TimeGenerated desc

// Cost data validation
AzureCostData_CL
| where Cost_d <= 0 or isnull(Cost_d)
| project TimeGenerated, ResourceName_s, Cost_d, ServiceName_s

// Email delivery tracking
AzureDiagnostics
| where Category == "JobStreams"
| where StreamType_s == "Output"
| where ResultDescription contains "email"
| order by TimeGenerated desc
```

#### PowerShell Debugging
```powershell
# Get runbook job output
$jobId = "your-job-id"
az automation job output show --automation-account-name "aa-nip-costing-dev-eus" --resource-group "rg-nip-costing-dev-eus" --name $jobId

# View runbook content
az automation runbook show --automation-account-name "aa-nip-costing-dev-eus" --resource-group "rg-nip-costing-dev-eus" --name "rb-cost-collection"
```

## Security Considerations

### Authentication & Authorization

#### Managed Identity Permissions
- **Cost Management Reader**: Read cost data from all subscriptions
- **Reader**: Access to subscription metadata and resources
- **Billing Reader**: Access to billing information
- **Log Analytics Contributor**: Write data to Log Analytics workspace

#### Key Vault Security
- Access policies restricted to automation account managed identity
- Encryption at rest enabled by default
- Network access restrictions (optional for production)
- Purge protection disabled for MVP (enable for production)

#### Data Protection
- All sensitive configuration stored in Key Vault or encrypted automation variables
- No credentials stored in Terraform state or source code
- Email client secrets rotated regularly (recommended: 90 days)
- API keys monitored for usage and rotated annually

### Network Security
- All communication over HTTPS/TLS
- Azure-to-Azure traffic remains within Microsoft backbone
- External API calls (Anthropic, Graph) use secure endpoints
- No inbound network access required

### Compliance Considerations
- Cost data retention aligns with financial compliance requirements
- Email reports contain no sensitive financial details beyond cost summaries
- Audit trail maintained through automation job logs
- Access logging enabled for Key Vault operations

## Cost Analysis

### Current MVP Costs (East US)

| Resource | Configuration | Monthly Cost |
|----------|--------------|--------------|
| **Log Analytics Workspace** | 1GB/day ingestion, 30-day retention | ~$2.50 |
| **Automation Account** | Basic tier, ~150 jobs/month | $0.00 |
| **Storage Account** | ZRS, Cool tier, <1GB data | ~$0.50 |
| **Key Vault** | Standard tier, <10K operations | ~$0.03 |
| **Data Collection Rules** | 1 rule, minimal VM metrics | ~$0.50 |
| **Total Azure Costs** | | **$3.53** |

### External API Costs
| Service | Usage | Monthly Cost |
|---------|-------|--------------|
| **Anthropic Claude 3.5 Haiku** | ~4 weekly reports, 2K tokens each | ~$1.00 |
| **Microsoft Graph API** | ~4 emails/month | $0.00 |
| **Total External Costs** | | **$1.00** |

### **Total Solution Cost: ~$4.53/month**

### Cost Scaling Projections

#### 5 Subscriptions
- Log Analytics: ~$5.00 (2GB/day)
- Other resources: ~$1.53
- **Total: ~$6.53/month**

#### 20 Subscriptions  
- Log Analytics: ~$15.00 (6GB/day)
- Other resources: ~$2.03
- **Total: ~$17.03/month**

### Cost Optimization Strategies

#### Short-term Optimizations
1. **Reduce data collection frequency** from daily to every 2-3 days
2. **Implement data sampling** for large subscriptions
3. **Optimize Log Analytics queries** to reduce compute costs
4. **Use consumption-based pricing** for Anthropic API

#### Long-term Optimizations
1. **Archive old cost data** to cheaper storage tiers
2. **Implement intelligent scheduling** based on cost change patterns
3. **Use Azure Functions** for smaller, event-driven workloads
4. **Implement local AI models** to reduce external API costs

## Scaling Strategy

### Multi-Subscription Scaling

#### Phase 1: MVP (1 Subscription)
- Current implementation
- Single subscription monitoring
- Basic email reporting
- ~$4.53/month cost

#### Phase 2: Department Scale (5-10 Subscriptions)
```terraform
target_subscription_ids = [
  "subscription-1-prod",
  "subscription-2-dev", 
  "subscription-3-test",
  "subscription-4-shared",
  "subscription-5-sandbox"
]
```
- Increase Log Analytics daily quota to 5GB
- Add subscription-level cost baselines
- Implement cost alerts
- ~$10-15/month cost

#### Phase 3: Enterprise Scale (20+ Subscriptions)
- Multiple automation accounts for load distribution
- Regional deployment for compliance
- Advanced AI analytics with cost prediction
- Integration with Azure Cost Management + Billing APIs
- ~$30-50/month cost

### Authentication Scaling

#### Production Authentication Migration
```terraform
# Replace Azure CLI auth with Service Principal
provider "azurerm" {
  features {}
  client_id       = var.client_id
  client_secret   = var.client_secret  
  tenant_id       = var.tenant_id
  subscription_id = var.management_subscription_id
}
```

#### Multi-Tenant Support
- Cross-tenant service principal configuration
- Lighthouse delegated access for MSP scenarios
- Centralized cost reporting across tenants

### Regional Deployment

#### Multi-Region Architecture
```
Primary Region (East US)
├── Central Log Analytics Workspace
├── Primary Automation Account
└── Central Storage Account

Secondary Region (West US 2)  
├── Regional Automation Account
├── Regional Data Collection
└── Backup/DR capabilities
```

### Advanced Features Roadmap

#### Q1 2025: Enhanced Analytics
- Predictive cost modeling
- Resource rightsizing recommendations
- Automated optimization suggestions
- Cost anomaly alerting

#### Q2 2025: Integration Expansion
- ServiceNow integration for cost approvals
- Slack/Teams notifications
- Azure DevOps work item creation for high costs
- Power BI dashboard integration

#### Q3 2025: Advanced Automation
- Auto-scaling based on cost thresholds
- Resource lifecycle management
- Budget enforcement automation
- Cost allocation and chargeback automation

## API Reference

### Azure Cost Management API

#### Query Cost Data
```http
POST https://management.azure.com/subscriptions/{subscription-id}/providers/Microsoft.CostManagement/query?api-version=2021-10-01

{
  "type": "ActualCost",
  "dataSet": {
    "granularity": "Daily",
    "aggregation": {
      "totalCost": {
        "name": "Cost",
        "function": "Sum"
      }
    },
    "sorting": [
      {
        "direction": "ascending",
        "name": "UsageDate"
      }
    ],
    "grouping": [
      {
        "type": "Dimension",
        "name": "ServiceName"
      }
    ]
  },
  "timeframe": "Custom",
  "timePeriod": {
    "from": "2025-01-01T00:00:00+00:00",
    "to": "2025-01-07T23:59:59+00:00"
  }
}
```

### Log Analytics REST API

#### Ingest Custom Data
```http
POST https://{workspace-id}.ods.opinsights.azure.com/api/logs?api-version=2016-04-01

Headers:
Authorization: Bearer {access-token}
Content-Type: application/json
Log-Type: AzureCostData

Body: [
  {
    "Cost": 125.50,
    "Currency": "USD", 
    "ServiceName": "Virtual Machines",
    "ResourceName": "vm-production-web01",
    "SubscriptionId": "12345678-1234-1234-1234-123456789012",
    "UsageDate": "2025-01-15",
    "IsAVDResource": false
  }
]
```

### Microsoft Graph API

#### Send Email
```http
POST https://graph.microsoft.com/v1.0/users/{user-id}/sendMail

{
  "message": {
    "subject": "Weekly Azure Cost Report",
    "body": {
      "contentType": "HTML",
      "content": "<html>...</html>"
    },
    "toRecipients": [
      {
        "emailAddress": {
          "address": "recipient@domain.com"
        }
      }
    ]
  }
}
```

### Anthropic Claude API

#### Cost Analysis Request
```http
POST https://api.anthropic.com/v1/messages

{
  "model": "claude-3-5-haiku-20241022",
  "max_tokens": 1000,
  "messages": [
    {
      "role": "user", 
      "content": "Analyze this Azure cost data and provide insights: {cost_data_json}"
    }
  ]
}
```

### PowerShell Module Reference

#### Key Functions Used
```powershell
# Azure Cost Management
Get-AzConsumptionUsageDetail
Invoke-AzRestMethod

# Log Analytics  
Invoke-AzOperationalInsightsQuery
Send-AzOperationalInsightsDataCollector

# Microsoft Graph
Invoke-RestMethod -Uri "https://graph.microsoft.com/v1.0/me/sendMail"

# Azure Automation
Get-AutomationVariable
Set-AutomationVariable
```

---

**Document Version**: 2.0  
**Last Updated**: July 24, 2025  
**Next Review**: October 2025  
**Maintainer**: DevOps Team  
**Contact**: costmgmt@yourdomain.com

---

### Appendix: Quick Reference Commands

#### Deployment
```powershell
terraform init && terraform plan && terraform apply -auto-approve
```

#### Manual Collection
```powershell
az automation runbook start --resource-group "rg-nip-costing-dev-eus" --automation-account-name "aa-nip-costing-dev-eus" --name "rb-cost-collection"
```

#### Data Query
```kql
AzureCostData_CL | where TimeGenerated >= ago(7d) | summarize sum(Cost_d) by ServiceName_s
```

#### Cleanup
```powershell
terraform destroy -auto-approve
```
