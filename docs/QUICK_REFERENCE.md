# Quick Reference Guide

## Essential Commands

### Deployment Commands
```powershell
# Full deployment from scratch
terraform init && terraform plan && terraform apply -auto-approve

# Check deployment outputs
terraform output

# Verify specific resource
terraform output -raw resource_group_name
```

### Manual Runbook Execution
```powershell
# Start cost collection
az automation runbook start --resource-group "rg-nip-costing-dev-eus" --automation-account-name "aa-nip-costing-dev-eus" --name "rb-cost-collection"

# Start weekly analysis
az automation runbook start --resource-group "rg-nip-costing-dev-eus" --automation-account-name "aa-nip-costing-dev-eus" --name "rb-weekly-analysis"

# Check job status
az automation job list --resource-group "rg-nip-costing-dev-eus" --automation-account-name "aa-nip-costing-dev-eus" --output table
```

### Monitoring Queries

#### Check Recent Cost Data
```kql
AzureCostData_CL
| where TimeGenerated >= ago(7d)
| summarize TotalCost = sum(Cost_d), RecordCount = count() by bin(TimeGenerated, 1d)
| order by TimeGenerated desc
```

#### Validate Data Quality
```kql
AzureCostData_CL
| where TimeGenerated >= ago(2d)
| summarize 
    TotalRecords = count(),
    InvalidCosts = countif(Cost_d <= 0 or isnull(Cost_d)),
    UniqueSubscriptions = dcount(SubscriptionId_s),
    UniqueServices = dcount(ServiceName_s)
```

#### Top Services by Cost
```kql
AzureCostData_CL
| where TimeGenerated >= ago(30d)
| summarize TotalCost = sum(Cost_d) by ServiceName_s
| order by TotalCost desc
| take 10
```

### Troubleshooting

#### Check Managed Identity Permissions
```powershell
$principalId = az automation account show --resource-group "rg-nip-costing-dev-eus" --automation-account-name "aa-nip-costing-dev-eus" --query "identity.principalId" -o tsv
az role assignment list --assignee $principalId --output table
```

#### View Automation Variables
```powershell
az automation variable list --resource-group "rg-nip-costing-dev-eus" --automation-account-name "aa-nip-costing-dev-eus" --output table
```

#### Check Schedules
```powershell
az automation schedule list --resource-group "rg-nip-costing-dev-eus" --automation-account-name "aa-nip-costing-dev-eus" --output table
```

## Configuration Files

### Required terraform.tfvars
```hcl
# Subscription Configuration
management_subscription_id = "e653ba88-fc91-42f4-b22b-c35e36b00835"
target_subscription_ids = ["e653ba88-fc91-42f4-b22b-c35e36b00835"]

# Email Configuration
email_from_address = "costmgmt@yourdomain.com"
email_client_id = "your-app-registration-client-id"
email_tenant_id = "your-tenant-id"
email_client_secret = "your-client-secret"
cost_report_recipients = "admin@domain.com,manager@domain.com"

# AI Configuration
anthropic_api_key = "sk-ant-api03-your-key-here"
```

## Resource Information

### Resource Names
- Resource Group: `rg-nip-costing-dev-eus`
- Automation Account: `aa-nip-costing-dev-eus`
- Log Analytics: `law-nip-costing-dev-eus`
- Storage Account: `stnipcostingdev<random>`
- Key Vault: `kv-dev-cost-<random>`

### Runbook Names
- Cost Collection: `rb-cost-collection`
- Weekly Analysis: `rb-weekly-analysis`
- Baseline Calculation: `rb-baseline-calculation`

### Schedule Information
- Cost Collection: Daily at 02:00 EST
- Weekly Analysis: Sundays at 06:00 EST

## Common Issues & Solutions

### Issue: No cost data appearing
**Check:**
1. Managed identity permissions
2. Subscription IDs in automation variables
3. Cost Management API access

**Solution:**
```powershell
# Re-assign permissions
az role assignment create --assignee $principalId --role "Cost Management Reader" --scope "/subscriptions/SUBSCRIPTION_ID"
```

### Issue: Email not being sent
**Check:**
1. Azure AD app permissions (Mail.Send)
2. Client secret expiration
3. Recipient email addresses

**Solution:**
```powershell
# Check automation variables for email config
az automation variable show --resource-group "rg-nip-costing-dev-eus" --automation-account-name "aa-nip-costing-dev-eus" --name "EMAIL_FROM_ADDRESS"
```

### Issue: High Log Analytics costs
**Check:**
```kql
Usage
| where TimeGenerated >= ago(7d)
| summarize TotalGB = sum(Quantity) / 1000 by DataType
| order by TotalGB desc
```

**Solution:**
- Reduce data collection frequency
- Implement data sampling
- Optimize retention policies

## Emergency Procedures

### Stop All Automation
```powershell
# Disable all schedules
az automation schedule list --resource-group "rg-nip-costing-dev-eus" --automation-account-name "aa-nip-costing-dev-eus" --query "[].name" -o tsv | ForEach-Object {
    az automation schedule update --resource-group "rg-nip-costing-dev-eus" --automation-account-name "aa-nip-costing-dev-eus" --name $_ --is-enabled false
}
```

### Complete Cleanup
```powershell
terraform destroy -auto-approve
```

### Data Reset (Testing Only)
```powershell
# Run the reset script
.\scripts\Reset-LogAnalyticsData-RestAPI.ps1 -TestMode
```

## Cost Monitoring

### Current Cost: ~$4.53/month
- Azure Resources: $3.53
- External APIs: $1.00

### Monitor Usage
```kql
// Log Analytics usage
Usage
| where TimeGenerated >= ago(30d)
| summarize DataVolume = sum(Quantity) by DataType
| project DataType, DataVolumeGB = DataVolume / 1000
```

## Support Contacts

- **Technical Issues**: DevOps Team
- **Cost Questions**: Finance Team  
- **Access Issues**: Azure Administrators
- **Email**: costmgmt@yourdomain.com

---
**Quick Reference Version**: 1.0  
**Last Updated**: July 24, 2025
