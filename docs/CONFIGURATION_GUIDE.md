# Configuration Guide

## Overview

This guide provides detailed configuration instructions for the Azure Cost Management Automation solution. Follow these steps to properly configure all components for successful deployment and operation.

## Prerequisites Configuration

### 1. Azure Subscription Setup

#### Required Permissions
Your Azure account needs the following permissions on target subscriptions:
- **Cost Management Reader**: To read cost and billing data
- **Reader**: To access resource metadata
- **Billing Reader**: For detailed billing information
- **Contributor**: On the management subscription for resource deployment

#### Verify Permissions
```powershell
# Check current user permissions
az role assignment list --assignee $(az ad signed-in-user show --query objectId -o tsv) --output table

# Check specific subscription access
az role assignment list --assignee $(az ad signed-in-user show --query objectId -o tsv) --scope "/subscriptions/e653ba88-fc91-42f4-b22b-c35e36b00835" --output table
```

### 2. Azure AD App Registration for Email

#### Step 1: Create App Registration
```powershell
# Create the app registration
$appName = "app-nip-costing-email-dev"
$app = az ad app create --display-name $appName --query "{appId:appId, objectId:id}" -o json | ConvertFrom-Json

Write-Host "App ID: $($app.appId)"
Write-Host "Object ID: $($app.objectId)"
```

#### Step 2: Configure API Permissions
```powershell
# Add Microsoft Graph Mail.Send permission
az ad app permission add --id $app.appId --api 00000003-0000-0000-c000-000000000000 --api-permissions b633e1c5-b582-4048-a93e-9f11b44c7e96=Role

# Grant admin consent (requires Global Admin or Application Admin role)
az ad app permission admin-consent --id $app.appId
```

#### Step 3: Create Client Secret
```powershell
# Create client secret (valid for 24 months)
$secret = az ad app credential reset --id $app.appId --display-name "CostManagement-Secret" --years 2 --query password -o tsv

Write-Host "Client Secret: $secret"
Write-Host "⚠️  Save this secret securely - it cannot be retrieved again!"
```

#### Step 4: Get Tenant Information
```powershell
# Get tenant ID
$tenantId = az account show --query tenantId -o tsv
Write-Host "Tenant ID: $tenantId"
```

### 3. Anthropic API Key Setup

#### Step 1: Create Anthropic Account
1. Visit https://console.anthropic.com
2. Create an account or sign in
3. Navigate to "API Keys" section
4. Create a new API key

#### Step 2: Configure API Key
```powershell
# Test API key (replace with your actual key)
$anthropicKey = "sk-ant-api03-your-key-here"

# Test API connectivity
$headers = @{
    "x-api-key" = $anthropicKey
    "Content-Type" = "application/json"
}

$body = @{
    model = "claude-3-5-haiku-20241022"
    max_tokens = 100
    messages = @(
        @{
            role = "user"
            content = "Hello, this is a test."
        }
    )
} | ConvertTo-Json -Depth 3

try {
    $response = Invoke-RestMethod -Uri "https://api.anthropic.com/v1/messages" -Method POST -Headers $headers -Body $body
    Write-Host "✅ Anthropic API key is valid"
} catch {
    Write-Host "❌ Anthropic API key test failed: $($_.Exception.Message)"
}
```

## Configuration Files

### 1. terraform.tfvars Configuration

Create your `terraform.tfvars` file based on the template:

```powershell
# Copy the example file
Copy-Item "terraform.tfvars.example" "terraform.tfvars"
```

#### Complete terraform.tfvars Template
```hcl
# ==================================================
# Azure Cost Management Automation Configuration
# ==================================================

# Subscription Configuration
management_subscription_id = "e653ba88-fc91-42f4-b22b-c35e36b00835"
target_subscription_ids = [
  "e653ba88-fc91-42f4-b22b-c35e36b00835",
  # Add additional subscription IDs here for multi-subscription monitoring
  # "12345678-1234-1234-1234-123456789012",
  # "87654321-4321-4321-4321-210987654321"
]

# Email Configuration (from Azure AD App Registration)
email_from_address     = "costmgmt@yourdomain.com"           # Sender email address
email_client_id        = "12345678-1234-1234-1234-123456789012"  # App Registration Client ID
email_tenant_id        = "87654321-4321-4321-4321-210987654321"  # Azure AD Tenant ID  
email_client_secret    = "your-client-secret-from-step-3"    # Client secret from app registration
cost_report_recipients = "admin@yourdomain.com,manager@yourdomain.com,finance@yourdomain.com"

# AI Configuration
anthropic_api_key = "sk-ant-api03-your-anthropic-api-key-here"

# ==================================================
# Optional Configuration (Advanced)
# ==================================================

# Resource Configuration (Optional - uses defaults if not specified)
# location = "eastus"
# environment = "dev" 
# project_name = "nip-costing"

# Data Retention Configuration (Optional)
# cost_data_retention_days = 365    # Cost data retention (default: 365 days)
# log_retention_days = 30           # Operational log retention (default: 30 days)

# Feature Flags (Optional - all default to true)
# enable_advanced_prompting = true              # Chain-of-thought AI analysis
# include_anomaly_detection = true              # Statistical anomaly detection
# include_chargeback_analysis = true            # Tag compliance analysis
# include_forecasting = true                    # Cost forecasting
# include_optimization_recommendations = true   # Azure Advisor integration

# Extended Configuration (Optional)
# enable_extended_retention = false             # 90-day retention for operational data
# project_owner = "DevOps Team"                 # Project owner for tagging
# cost_center = "IT"                           # Cost center for tagging
```

### 2. Environment-Specific Configurations

#### Development Environment
```hcl
# terraform.tfvars.dev
environment = "dev"
log_retention_days = 30
cost_data_retention_days = 90
enable_extended_retention = false
target_subscription_ids = ["dev-subscription-id"]
```

#### Production Environment  
```hcl
# terraform.tfvars.prod
environment = "prod"
log_retention_days = 90
cost_data_retention_days = 2555  # 7 years
enable_extended_retention = true
target_subscription_ids = [
  "prod-subscription-1",
  "prod-subscription-2", 
  "shared-services-subscription"
]
```

## Post-Deployment Configuration

### 1. Verify Automation Variables

After deployment, verify that automation variables are properly configured:

```powershell
# List all automation variables
az automation variable list --resource-group "rg-nip-costing-dev-eus" --automation-account-name "aa-nip-costing-dev-eus" --output table

# Check specific variables
$variables = @(
    "TARGET_SUBSCRIPTION_IDS",
    "EMAIL_FROM_ADDRESS", 
    "EMAIL_CLIENT_ID",
    "EMAIL_TENANT_ID",
    "COST_REPORT_RECIPIENTS",
    "ENABLE_ADVANCED_PROMPTING",
    "INCLUDE_ANOMALY_DETECTION"
)

foreach ($var in $variables) {
    try {
        $value = az automation variable show --resource-group "rg-nip-costing-dev-eus" --automation-account-name "aa-nip-costing-dev-eus" --name $var --query value -o tsv
        Write-Host "✅ $var`: $value"
    } catch {
        Write-Host "❌ $var`: Not found or not accessible"
    }
}
```

### 2. Verify Key Vault Secrets

```powershell
# Get Key Vault name
$keyVaultName = terraform output -raw key_vault_name

# List secrets (requires Key Vault access)
az keyvault secret list --vault-name $keyVaultName --output table

# Verify specific secrets exist (without showing values)
$secrets = @("anthropic-api-key", "email-client-secret")
foreach ($secret in $secrets) {
    try {
        az keyvault secret show --vault-name $keyVaultName --name $secret --query name -o tsv | Out-Null
        Write-Host "✅ Secret '$secret' exists in Key Vault"
    } catch {
        Write-Host "❌ Secret '$secret' not found in Key Vault"
    }
}
```

### 3. Verify Managed Identity Permissions

```powershell
# Get automation account managed identity principal ID
$principalId = az automation account show --resource-group "rg-nip-costing-dev-eus" --automation-account-name "aa-nip-costing-dev-eus" --query "identity.principalId" -o tsv

Write-Host "Automation Account Principal ID: $principalId"

# Check role assignments
az role assignment list --assignee $principalId --output table

# Verify required roles on each subscription
$requiredRoles = @("Cost Management Reader", "Reader", "Billing Reader")
$subscriptions = (terraform output -json target_subscription_ids | ConvertFrom-Json)

foreach ($subscription in $subscriptions) {
    Write-Host "`nChecking permissions on subscription: $subscription"
    foreach ($role in $requiredRoles) {
        $assignment = az role assignment list --assignee $principalId --role $role --scope "/subscriptions/$subscription" --query "[0].roleDefinitionName" -o tsv
        if ($assignment) {
            Write-Host "✅ $role`: Assigned"
        } else {
            Write-Host "❌ $role`: Missing"
        }
    }
}
```

## Configuration Validation

### 1. Test Cost Data Collection

```powershell
# Start cost collection runbook manually
$jobId = az automation runbook start --resource-group "rg-nip-costing-dev-eus" --automation-account-name "aa-nip-costing-dev-eus" --name "rb-cost-collection" --query name -o tsv

Write-Host "Started job: $jobId"

# Monitor job status
do {
    $status = az automation job show --automation-account-name "aa-nip-costing-dev-eus" --resource-group "rg-nip-costing-dev-eus" --name $jobId --query status -o tsv
    Write-Host "Job status: $status"
    if ($status -eq "Running") { Start-Sleep 30 }
} while ($status -eq "Running")

# Get final status and output
az automation job show --automation-account-name "aa-nip-costing-dev-eus" --resource-group "rg-nip-costing-dev-eus" --name $jobId --query "{status:status, startTime:startTime, endTime:endTime}" -o table
```

### 2. Test Email Functionality

```powershell
# Start weekly analysis runbook to test email
$emailJobId = az automation runbook start --resource-group "rg-nip-costing-dev-eus" --automation-account-name "aa-nip-costing-dev-eus" --name "rb-weekly-analysis" --query name -o tsv

Write-Host "Started email test job: $emailJobId"

# Monitor and check for email delivery
# Check email recipients' inboxes for test report
```

### 3. Verify Log Analytics Data

```powershell
# Get Log Analytics workspace ID
$workspaceId = terraform output -raw log_analytics_workspace_id

# Query for recent cost data
$query = "AzureCostData_CL | where TimeGenerated >= ago(2d) | summarize count() by bin(TimeGenerated, 1h) | order by TimeGenerated desc"

az monitor log-analytics query --workspace $workspaceId --analytics-query $query --output table
```

## Advanced Configuration

### 1. Multi-Region Deployment

For multi-region deployments, create separate Terraform configurations:

```hcl
# terraform.tfvars.eastus
location = "eastus"
location_abbreviation = "eus"
environment = "prod-east"

# terraform.tfvars.westus2  
location = "westus2"
location_abbreviation = "wus2"
environment = "prod-west"
```

### 2. Custom Email Templates

Email templates can be customized by modifying the PowerShell scripts:

```powershell
# Location: scripts/WeeklyAnalysisEngine-Automation.ps1
# Search for HTML template sections to customize

# Example customization areas:
# - Company branding/logos
# - Color schemes
# - Additional cost breakdown sections
# - Custom metrics and KPIs
```

### 3. Schedule Customization

Modify automation schedules via Terraform variables:

```hcl
# Custom schedule configuration (add to terraform.tfvars)
cost_collection_schedule = "0 2 * * *"    # Daily at 2 AM EST
weekly_analysis_schedule = "0 6 * * 0"    # Sundays at 6 AM EST
```

## Troubleshooting Configuration Issues

### Common Configuration Problems

#### 1. Email Permission Issues
```powershell
# Check app registration permissions
az ad app permission list --id $app.appId --output table

# Verify admin consent
az ad app permission list-grants --id $app.appId --output table
```

#### 2. Key Vault Access Issues
```powershell
# Check Key Vault access policies
az keyvault show --name $keyVaultName --query "properties.accessPolicies" --output table

# Verify managed identity has access
az keyvault show --name $keyVaultName --query "properties.accessPolicies[?objectId=='$principalId']" --output table
```

#### 3. Cost Management API Issues
```powershell
# Test Cost Management API access
$subscriptionId = (terraform output -json target_subscription_ids | ConvertFrom-Json)[0]
az rest --method POST --url "https://management.azure.com/subscriptions/$subscriptionId/providers/Microsoft.CostManagement/query?api-version=2021-10-01" --body '{"type":"ActualCost","dataSet":{"granularity":"Daily"},"timeframe":"MonthToDate"}'
```

### Configuration Validation Script

```powershell
# Complete configuration validation script
function Test-AzureCostManagementConfig {
    Write-Host "🔍 Starting Azure Cost Management Configuration Validation..." -ForegroundColor Cyan
    
    # Test 1: Terraform outputs
    Write-Host "`n1️⃣ Testing Terraform Outputs..."
    try {
        $rgName = terraform output -raw resource_group_name
        $aaName = terraform output -raw automation_account_name
        $lawId = terraform output -raw log_analytics_workspace_id
        Write-Host "✅ Terraform outputs accessible" -ForegroundColor Green
    } catch {
        Write-Host "❌ Terraform outputs failed: $($_.Exception.Message)" -ForegroundColor Red
        return
    }
    
    # Test 2: Resource existence
    Write-Host "`n2️⃣ Testing Resource Existence..."
    try {
        az group show --name $rgName --output none
        az automation account show --resource-group $rgName --automation-account-name $aaName --output none
        Write-Host "✅ Core resources exist" -ForegroundColor Green
    } catch {
        Write-Host "❌ Resource check failed: $($_.Exception.Message)" -ForegroundColor Red
    }
    
    # Test 3: Automation variables
    Write-Host "`n3️⃣ Testing Automation Variables..."
    $requiredVars = @("TARGET_SUBSCRIPTION_IDS", "EMAIL_FROM_ADDRESS", "COST_REPORT_RECIPIENTS")
    $missingVars = @()
    
    foreach ($var in $requiredVars) {
        try {
            az automation variable show --resource-group $rgName --automation-account-name $aaName --name $var --output none
            Write-Host "✅ $var exists" -ForegroundColor Green
        } catch {
            Write-Host "❌ $var missing" -ForegroundColor Red
            $missingVars += $var
        }
    }
    
    # Test 4: Managed identity permissions
    Write-Host "`n4️⃣ Testing Managed Identity Permissions..."
    $principalId = az automation account show --resource-group $rgName --automation-account-name $aaName --query "identity.principalId" -o tsv
    $roleCount = (az role assignment list --assignee $principalId --query "length([?contains(roleDefinitionName, 'Cost Management') || contains(roleDefinitionName, 'Reader') || contains(roleDefinitionName, 'Billing')])" -o tsv)
    
    if ($roleCount -ge 3) {
        Write-Host "✅ Managed identity has required permissions" -ForegroundColor Green
    } else {
        Write-Host "❌ Managed identity missing permissions (found $roleCount of 3+ required)" -ForegroundColor Red
    }
    
    # Test 5: Test cost collection
    Write-Host "`n5️⃣ Testing Cost Collection..."
    try {
        $jobId = az automation runbook start --resource-group $rgName --automation-account-name $aaName --name "rb-cost-collection" --query name -o tsv
        Write-Host "✅ Cost collection runbook started successfully (Job: $jobId)" -ForegroundColor Green
    } catch {
        Write-Host "❌ Cost collection test failed: $($_.Exception.Message)" -ForegroundColor Red
    }
    
    Write-Host "`n🏁 Configuration validation complete!" -ForegroundColor Cyan
    
    if ($missingVars.Count -eq 0) {
        Write-Host "✅ All critical configurations are valid" -ForegroundColor Green
    } else {
        Write-Host "⚠️  Please fix missing variables: $($missingVars -join ', ')" -ForegroundColor Yellow
    }
}

# Run the validation
Test-AzureCostManagementConfig
```

## Security Configuration

### 1. Network Security

For production environments, consider implementing network restrictions:

```hcl
# Add to variables.tf for network security
variable "allowed_ip_ranges" {
  description = "IP ranges allowed to access Key Vault"
  type        = list(string)
  default     = []  # Empty for MVP, populate for production
}

variable "enable_private_endpoints" {
  description = "Enable private endpoints for secure access"
  type        = bool
  default     = false  # Set to true for production
}
```

### 2. Key Rotation

Set up automated key rotation:

```powershell
# Schedule for quarterly secret rotation
# Add to automation schedules or Azure Key Vault rotation policies

# Example: Rotate Anthropic API key every 365 days
# Example: Rotate email client secret every 90 days
```

### 3. Audit and Compliance

Enable auditing for compliance:

```hcl
# Add diagnostic settings for audit logging
resource "azurerm_monitor_diagnostic_setting" "key_vault_audit" {
  name                       = "kv-audit-logs"
  target_resource_id         = azurerm_key_vault.cost_management.id
  log_analytics_workspace_id = azurerm_log_analytics_workspace.cost_management.id

  enabled_log {
    category = "AuditEvent"
  }
  
  metric {
    category = "AllMetrics"
  }
}
```

---

**Configuration Guide Version**: 1.0  
**Last Updated**: July 24, 2025  
**Next Review**: October 2025  
**Support**: costmgmt@yourdomain.com
