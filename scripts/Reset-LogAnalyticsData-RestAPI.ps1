# Reset-LogAnalyticsData-RestAPI.ps1
# Advanced script using Azure REST API for complete Log Analytics workspace data purge
# Purges all custom tables for Azure Cost Management automation project
# Now includes: Cost Data, Baseline, Historical, Invoice, Advisor, Forecast, and Reservation tables

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$SubscriptionId = "e653ba88-fc91-42f4-b22b-c35e36b00835",
    
    [Parameter(Mandatory = $false)]
    [string]$ResourceGroupName = "rg-nip-costing-dev-eus",
    
    [Parameter(Mandatory = $false)]
    [string]$WorkspaceName = "law-nip-costing-dev-eus",
    
    [Parameter(Mandatory = $false)]
    [switch]$Force,
    
    [Parameter(Mandatory = $false)]
    [switch]$TestMode,
    
    [Parameter(Mandatory = $false)]
    [int]$PurgeDays = 90  # Purge data from last N days (max 90)
)

# Import required modules
Import-Module Az.Accounts -Force
Import-Module Az.Profile -Force

# Custom tables specific to the cost management project
$CustomTables = @(
    "AzureAdvisorRecommendations_CL",
    "AzureCostBaseline_CL",
    "AzureCostData_CL",
    "AzureCostForecast_CL",
    "AzureHistoricalCostData_CL",
    "AzureInvoiceData_CL",  # DEPRECATED - contains 11 legacy records
    "AzureReservationUtilization_CL"
)

# Function to write timestamped log messages
function Write-LogMessage {
    param([string]$Message, [string]$Level = "INFO")
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $color = switch ($Level) {
        "ERROR" { "Red" }
        "WARN" { "Yellow" }
        "SUCCESS" { "Green" }
        default { "Cyan" }
    }
    Write-Host "[$timestamp] [$Level] $Message" -ForegroundColor $color
}

# Function to get access token for Azure REST API
function Get-AzureAccessToken {
    try {
        $context = Get-AzContext
        if (-not $context) {
            throw "Not connected to Azure. Please run Connect-AzAccount first."
        }
        
        $token = [Microsoft.Azure.Commands.Common.Authentication.AzureSession]::Instance.AuthenticationFactory.Authenticate($context.Account, $context.Environment, $context.Tenant.Id, $null, "https://management.azure.com/", $null).AccessToken
        return $token
    }
    catch {
        Write-LogMessage "Failed to get access token: $($_.Exception.Message)" "ERROR"
        return $null
    }
}

# Function to invoke Azure REST API
function Invoke-AzureRestAPI {
    param(
        [string]$Uri,
        [string]$Method = "GET",
        [string]$Body = $null,
        [hashtable]$Headers = @{}
    )
    
    try {
        $token = Get-AzureAccessToken
        if (-not $token) {
            throw "Cannot get access token"
        }
        
        $defaultHeaders = @{
            "Authorization" = "Bearer $token"
            "Content-Type" = "application/json"
        }
        
        $allHeaders = $defaultHeaders + $Headers
        
        $params = @{
            Uri = $Uri
            Method = $Method
            Headers = $allHeaders
        }
        
        if ($Body) {
            $params.Body = $Body
        }
        
        $response = Invoke-RestMethod @params
        return $response
    }
    catch {
        Write-LogMessage "REST API call failed: $($_.Exception.Message)" "ERROR"
        throw
    }
}

# Function to get workspace information
function Get-WorkspaceInfo {
    param(
        [string]$SubscriptionId,
        [string]$ResourceGroupName,
        [string]$WorkspaceName
    )
    
    try {
        $uri = "https://management.azure.com/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroupName/providers/Microsoft.OperationalInsights/workspaces/$WorkspaceName" + "?api-version=2021-06-01"
        
        $workspace = Invoke-AzureRestAPI -Uri $uri -Method "GET"
        
        Write-LogMessage "Workspace found: $($workspace.name)" "SUCCESS"
        Write-LogMessage "Workspace ID: $($workspace.properties.customerId)" "INFO"
        Write-LogMessage "Location: $($workspace.location)" "INFO"
        
        return $workspace
    }
    catch {
        Write-LogMessage "Failed to get workspace info: $($_.Exception.Message)" "ERROR"
        return $null
    }
}

# Function to purge table data using REST API
function Invoke-TablePurgeAPI {
    param(
        [string]$SubscriptionId,
        [string]$ResourceGroupName,
        [string]$WorkspaceName,
        [string]$TableName,
        [int]$PurgeDays,
        [switch]$WhatIf
    )
    
    try {
        # Calculate purge timespan
        $purgeDateTime = (Get-Date).AddDays(-$PurgeDays).ToString("yyyy-MM-ddTHH:mm:ss.fffZ")
        
        if ($TestMode) {
            Write-LogMessage "TESTMODE: Would purge $TableName data from $purgeDateTime to now" "WARN"
            return @{ Status = "TestMode"; PurgeId = "N/A" }
        }
        
        # Prepare purge request
        $purgeBody = @{
            table = $TableName
            filters = @(
                @{
                    column = "TimeGenerated"
                    operator = ">"
                    value = $purgeDateTime
                }
            )
        } | ConvertTo-Json -Depth 3
        
        $uri = "https://management.azure.com/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroupName/providers/Microsoft.OperationalInsights/workspaces/$WorkspaceName/purge" + "?api-version=2020-08-01"
        
        Write-LogMessage "Initiating purge for $TableName (data since $purgeDateTime)"
        
        $purgeResponse = Invoke-AzureRestAPI -Uri $uri -Method "POST" -Body $purgeBody
        
        Write-LogMessage "Purge initiated for $TableName. Purge ID: $($purgeResponse.operationId)" "SUCCESS"
        
        return @{
            Status = "Initiated"
            PurgeId = $purgeResponse.operationId
            Table = $TableName
        }
    }
    catch {
        Write-LogMessage "Failed to purge $TableName : $($_.Exception.Message)" "ERROR"
        return @{
            Status = "Failed"
            PurgeId = $null
            Table = $TableName
            Error = $_.Exception.Message
        }
    }
}

# Function to check purge operation status
function Get-PurgeOperationStatus {
    param(
        [string]$SubscriptionId,
        [string]$ResourceGroupName,
        [string]$WorkspaceName,
        [string]$PurgeId
    )
    
    try {
        $uri = "https://management.azure.com/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroupName/providers/Microsoft.OperationalInsights/workspaces/$WorkspaceName/operations/$PurgeId" + "?api-version=2020-08-01"
        
        $status = Invoke-AzureRestAPI -Uri $uri -Method "GET"
        
        return $status
    }
    catch {
        Write-LogMessage "Failed to get purge status for $PurgeId : $($_.Exception.Message)" "ERROR"
        return $null
    }
}

# Function to execute complete workspace reset
function Start-WorkspaceReset {
    param(
        [string]$SubscriptionId,
        [string]$ResourceGroupName,
        [string]$WorkspaceName,
        [array]$TablesToReset,
        [int]$PurgeDays,
        [switch]$WhatIf
    )
    
    $purgeOperations = @()
    
    Write-LogMessage "Starting workspace reset for $($TablesToReset.Count) tables..." "INFO"
    
    foreach ($table in $TablesToReset) {
        $result = Invoke-TablePurgeAPI -SubscriptionId $SubscriptionId -ResourceGroupName $ResourceGroupName -WorkspaceName $WorkspaceName -TableName $table -PurgeDays $PurgeDays -WhatIf:$WhatIf
        $purgeOperations += $result
        
        Start-Sleep -Seconds 1  # Rate limiting
    }
    
    return $purgeOperations
}

# Function to monitor purge operations
function Watch-PurgeOperations {
    param(
        [string]$SubscriptionId,
        [string]$ResourceGroupName,
        [string]$WorkspaceName,
        [array]$PurgeOperations,
        [int]$TimeoutMinutes = 30
    )
    
    if ($PurgeOperations | Where-Object { $_.Status -eq "WhatIf" }) {
        Write-LogMessage "WhatIf mode - no operations to monitor" "INFO"
        return
    }
    
    $activeOperations = $PurgeOperations | Where-Object { $_.Status -eq "Initiated" }
    if ($activeOperations.Count -eq 0) {
        Write-LogMessage "No active purge operations to monitor" "WARN"
        return
    }
    
    Write-LogMessage "Monitoring $($activeOperations.Count) purge operations..." "INFO"
    
    $timeout = (Get-Date).AddMinutes($TimeoutMinutes)
    $completed = @()
    
    while ((Get-Date) -lt $timeout -and $completed.Count -lt $activeOperations.Count) {
        foreach ($operation in $activeOperations) {
            if ($operation.PurgeId -in $completed) {
                continue
            }
            
            $status = Get-PurgeOperationStatus -SubscriptionId $SubscriptionId -ResourceGroupName $ResourceGroupName -WorkspaceName $WorkspaceName -PurgeId $operation.PurgeId
            
            if ($status) {
                $statusText = $status.status
                Write-LogMessage "Table: $($operation.Table) | Status: $statusText | ID: $($operation.PurgeId)" "INFO"
                
                if ($statusText -eq "Completed" -or $statusText -eq "Failed") {
                    $completed += $operation.PurgeId
                    
                    if ($statusText -eq "Completed") {
                        Write-LogMessage "Purge completed for $($operation.Table)" "SUCCESS"
                    } else {
                        Write-LogMessage "Purge failed for $($operation.Table)" "ERROR"
                    }
                }
            }
        }
        
        if ($completed.Count -lt $activeOperations.Count) {
            Write-LogMessage "Waiting 30 seconds before next status check..." "INFO"
            Start-Sleep -Seconds 30
        }
    }
    
    if ($completed.Count -eq $activeOperations.Count) {
        Write-LogMessage "All purge operations completed!" "SUCCESS"
    } else {
        Write-LogMessage "Timeout reached. Some operations may still be running." "WARN"
        Write-LogMessage "Check Azure portal for final status." "INFO"
    }
}

# Main execution function
function Main {
    Write-LogMessage "=== Azure Cost Management Log Analytics Data Reset (REST API) ===" "INFO"
    Write-LogMessage "Subscription: $SubscriptionId" "INFO"
    Write-LogMessage "Resource Group: $ResourceGroupName" "INFO"
    Write-LogMessage "Workspace: $WorkspaceName" "INFO"
    Write-LogMessage "Purge Days: $PurgeDays" "INFO"
    Write-LogMessage "Force: $Force" "INFO"
    Write-LogMessage "WhatIf: $WhatIf" "INFO"
    
    # Check Azure connection
    $context = Get-AzContext
    if (-not $context) {
        Write-LogMessage "Not connected to Azure. Connecting..." "WARN"
        try {
            if ($env:AUTOMATION_RESOURCE_GROUP_NAME) {
                Connect-AzAccount -Identity -Subscription $SubscriptionId
            } else {
                Connect-AzAccount -Subscription $SubscriptionId
            }
        }
        catch {
            Write-LogMessage "Failed to connect to Azure: $($_.Exception.Message)" "ERROR"
            exit 1
        }
    }
    
    # Verify workspace exists
    $workspace = Get-WorkspaceInfo -SubscriptionId $SubscriptionId -ResourceGroupName $ResourceGroupName -WorkspaceName $WorkspaceName
    if (-not $workspace) {
        Write-LogMessage "Cannot proceed without valid workspace. Exiting." "ERROR"
        exit 1
    }
    
    # Show tables to be reset
    Write-LogMessage "Tables to reset: $($CustomTables -join ', ')" "INFO"
    
    # Confirmation prompt
    if (-not $Force -and -not $WhatIf) {
        Write-LogMessage "WARNING: This will permanently delete data from $($CustomTables.Count) tables!" "WARN"
        Write-LogMessage "Data from the last $PurgeDays days will be purged." "WARN"
        $confirmation = Read-Host "Type 'RESET' to confirm"
        if ($confirmation -ne "RESET") {
            Write-LogMessage "Operation cancelled by user." "INFO"
            return
        }
    }
    
    # Execute reset
    $purgeResults = Start-WorkspaceReset -SubscriptionId $SubscriptionId -ResourceGroupName $ResourceGroupName -WorkspaceName $WorkspaceName -TablesToReset $CustomTables -PurgeDays $PurgeDays -WhatIf:$WhatIf
    
    # Show immediate results
    Write-LogMessage "=== PURGE INITIATION RESULTS ===" "INFO"
    foreach ($result in $purgeResults) {
        $status = $result.Status
        $table = $result.Table
        if ($status -eq "Initiated") {
            Write-LogMessage "$table : $status (ID: $($result.PurgeId))" "SUCCESS"
        } elseif ($status -eq "WhatIf") {
            Write-LogMessage "$table : $status" "WARN"
        } else {
            Write-LogMessage "$table : $status" "ERROR"
            if ($result.Error) {
                Write-LogMessage "  Error: $($result.Error)" "ERROR"
            }
        }
    }
    
    # Monitor operations if not WhatIf
    if (-not $WhatIf) {
        Write-LogMessage "Starting operation monitoring..." "INFO"
        Watch-PurgeOperations -SubscriptionId $SubscriptionId -ResourceGroupName $ResourceGroupName -WorkspaceName $WorkspaceName -PurgeOperations $purgeResults -TimeoutMinutes 30
    }
    
    # Final summary
    Write-LogMessage "=== FINAL SUMMARY ===" "INFO"
    $initiated = ($purgeResults | Where-Object { $_.Status -eq "Initiated" }).Count
    $failed = ($purgeResults | Where-Object { $_.Status -eq "Failed" }).Count
    $whatif = ($purgeResults | Where-Object { $_.Status -eq "WhatIf" }).Count
    
    Write-LogMessage "Total tables: $($CustomTables.Count)" "INFO"
    Write-LogMessage "Purge initiated: $initiated" "SUCCESS"
    Write-LogMessage "Failed: $failed" "ERROR"
    if ($whatif -gt 0) {
        Write-LogMessage "WhatIf operations: $whatif" "INFO"
    }
    
    if (-not $WhatIf -and $initiated -gt 0) {
        Write-LogMessage "Purge operations may take several hours to complete fully." "INFO"
        Write-LogMessage "Monitor progress in Azure portal under Log Analytics workspace > Logs > Data purge." "INFO"
    }
}

# Execute script
try {
    Main
}
catch {
    Write-LogMessage "Script execution failed: $($_.Exception.Message)" "ERROR"
    exit 1
}
finally {
    Write-LogMessage "Script execution completed." "INFO"
}
