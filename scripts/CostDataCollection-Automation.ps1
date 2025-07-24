# Enhanced Cost Data Collection Runbook for Azure Cost Management
# Version 2.2 - Fixed data parsing issues and improved error handling
# 
# Key fixes implemented:
# - Enhanced record validation to prevent processing debug output as cost data
# - Improved numeric validation for cost values to ensure data integrity
# - Added comprehensive error handling for budget collection API errors
# - Better handling of subscription types that don't support certain APIs
# - Reduced debug output contamination in cost records
# - Added record counting for better monitoring and troubleshooting
#
# This runbook collects cost data from multiple Azure subscriptions and stores it in Log Analytics

param(
    [string]$CollectionDate = (Get-Date -Format "yyyy-MM-dd"),
    [bool]$IncludeForecasting = $true,
    [bool]$IncludeBudgets = $true,
    [bool]$IncludeAdvisor = $true
)

# Helper Functions (moved to top for proper scope)

function Invoke-CostManagementQuery {
    param(
        [string]$Uri,
        [hashtable]$Headers,
        [string]$Body,
        [int]$MaxRetries = 5
    )
    
    $retryCount = 0
    $baseDelaySeconds = 30
    $costData = $null
    
    while ($retryCount -lt $MaxRetries -and $null -eq $costData) {
        try {
            Write-Output "Attempting Cost Management API call (attempt $($retryCount + 1) of $MaxRetries)"
            $response = Invoke-RestMethod -Uri $Uri -Method POST -Headers $Headers -Body $Body -ErrorAction Stop
            
            # Validate response structure
            if ($response -and $response.properties -and $response.properties.rows) {
                $costData = $response.properties.rows
                Write-Output "Retrieved $($costData.Count) cost records"
                
                # Only log first record structure once for debugging, and only if we have valid data
                if ($costData.Count -gt 0) {
                    $firstRecord = $costData[0]
                    # Validate that this is actually cost data (numeric cost value expected)
                    if ($firstRecord -is [array] -and $firstRecord.Count -ge 4 -and $firstRecord[0] -match "^\d+(\.\d+)?$") {
                        Write-Output "First record validated: $($firstRecord.Count) fields - Cost: $($firstRecord[0]), Date: $($firstRecord[1])"
                    } else {
                        Write-Warning "First record format unexpected - may contain invalid data"
                    }
                }
                return $costData
            } else {
                Write-Warning "API response missing expected data structure"
                return @()  # Return empty array instead of null
            }
        } catch {
            $retryCount++
            $errorMessage = $_.Exception.Message
            $statusCode = $null
            
            # Extract status code from various error formats
            if ($_.Exception.Response) {
                $statusCode = $_.Exception.Response.StatusCode
            } elseif ($errorMessage -match "(\d{3})") {
                $statusCode = $matches[1]
            }
            
            Write-Warning "API call failed (attempt $retryCount): $errorMessage"
            
            # Handle specific error conditions with detailed logging
            if ($statusCode -eq 400) {
                Write-Warning "Bad Request (400) - Request format may be invalid or subscription type unsupported."
                Write-Warning "Error details: $errorMessage"
                # For 400 errors, don't retry as it's likely a structural issue
                Write-Error "Persistent 400 error - request format invalid or unsupported subscription type for subscription"
                break
            } elseif ($statusCode -eq 429 -or $errorMessage -like "*Too Many Requests*") {
                if ($retryCount -lt $MaxRetries) {
                    $delaySeconds = $baseDelaySeconds * [Math]::Pow(2, $retryCount - 1)
                    $jitter = Get-Random -Minimum 1 -Maximum 10
                    $totalDelay = $delaySeconds + $jitter
                    Write-Output "Rate limited. Waiting $totalDelay seconds before retry..."
                    Start-Sleep -Seconds $totalDelay
                }
            } elseif ($statusCode -eq 401 -or $statusCode -eq 403) {
                Write-Error "Authentication/Authorization error. Check managed identity permissions for Cost Management Reader role."
                break
            } elseif ($statusCode -eq 404) {
                Write-Warning "No cost data found or subscription not accessible. Skipping."
                return @()  # Return empty array for 404
            } else {
                if ($retryCount -lt $MaxRetries) {
                    $delaySeconds = 5 * [Math]::Pow(2, $retryCount - 1)
                    Write-Output "Transient error. Waiting $delaySeconds seconds before retry..."
                    Start-Sleep -Seconds $delaySeconds
                }
            }
        }
    }
    
    # Return empty array if all retries failed
    Write-Warning "All retry attempts failed for Cost Management API call"
    return @()
}

function Send-LogAnalyticsData {
    param(
        [string]$WorkspaceId,
        [string]$WorkspaceKey,
        [string]$LogType,
        [PSCustomObject]$DataObject
    )
    
    $json = $DataObject | ConvertTo-Json -Depth 3 -Compress
    $body = [System.Text.Encoding]::UTF8.GetBytes($json)
    
    $method = "POST"
    $contentType = "application/json"
    $resource = "/api/logs"
    $rfc1123date = [DateTime]::UtcNow.ToString("r")
    $contentLength = $body.Length
    
    $xHeaders = "x-ms-date:" + $rfc1123date
    $stringToHash = $method + "`n" + $contentLength + "`n" + $contentType + "`n" + $xHeaders + "`n" + $resource
    
    $bytesToHash = [Text.Encoding]::UTF8.GetBytes($stringToHash)
    $keyBytes = [Convert]::FromBase64String($WorkspaceKey)
    
    $sha256 = New-Object System.Security.Cryptography.HMACSHA256
    $sha256.Key = $keyBytes
    $calculatedHash = $sha256.ComputeHash($bytesToHash)
    $encodedHash = [Convert]::ToBase64String($calculatedHash)
    $authorization = 'SharedKey {0}:{1}' -f $WorkspaceId, $encodedHash
    
    $uri = "https://" + $WorkspaceId + ".ods.opinsights.azure.com" + $resource + "?api-version=2016-04-01"
    
    $headers = @{
        "Authorization" = $authorization;
        "Log-Type" = $LogType;
        "x-ms-date" = $rfc1123date;
        "time-generated-field" = "TimeGenerated";
    }
    
    $maxRetries = 3
    $retryCount = 0
    
    while ($retryCount -lt $maxRetries) {
        try {
            $result = Invoke-RestMethod -Uri $uri -Method $method -ContentType $contentType -Headers $headers -Body $body -ErrorAction Stop
            return
        } catch {
            $retryCount++
            if ($retryCount -lt $maxRetries) {
                $delay = 2 * [Math]::Pow(2, $retryCount)
                Start-Sleep -Seconds $delay
            }
        }
    }
}

function Get-CostForecast {
    param(
        [string]$SubscriptionId,
        [string]$Token
    )
    
    $forecastUri = "https://management.azure.com/subscriptions/$SubscriptionId/providers/Microsoft.CostManagement/forecast?api-version=2023-11-01"
    
    $forecastBody = @{
        type = "Usage"
        timeframe = "Custom"
        timePeriod = @{
            from = (Get-Date).ToString("yyyy-MM-dd")
            to = (Get-Date).AddDays(30).ToString("yyyy-MM-dd")
        }
        dataset = @{
            granularity = "Daily"
            aggregation = @{
                totalCost = @{
                    name = "Cost"
                    function = "Sum"
                }
            }
        }
        includeActualCost = $false
        includeFreshPartialCost = $false
    } | ConvertTo-Json -Depth 10
    
    $headers = @{
        "Authorization" = "Bearer $Token"
        "Content-Type" = "application/json"
    }
    
    try {
        $response = Invoke-RestMethod -Uri $forecastUri -Method POST -Headers $headers -Body $forecastBody -ErrorAction Stop
        return $response.properties.rows | ForEach-Object {
            @{
                Date = $_[0]
                Cost = $_[1]
                ConfidenceLevelLow = $_[2]
                ConfidenceLevelHigh = $_[3]
            }
        }
    } catch {
        Write-Warning "Failed to get forecast data: $($_.Exception.Message)"
        return @()
    }
}

function Get-CurrentBudgetSpend {
    param(
        [object]$Budget,
        [string]$Token
    )
    
    $scope = $Budget.Id -replace '/providers/Microsoft.Consumption/budgets/.*', ''
    $currentDate = Get-Date
    $monthStart = Get-Date -Day 1
    
    $spendUri = "https://management.azure.com$scope/providers/Microsoft.CostManagement/query?api-version=2023-11-01"
    
    $spendBody = @{
        type = "ActualCost"
        timeframe = "Custom"
        timePeriod = @{
            from = $monthStart.ToString("yyyy-MM-dd")
            to = $currentDate.ToString("yyyy-MM-dd")
        }
        dataset = @{
            granularity = "None"
            aggregation = @{
                totalCost = @{
                    name = "Cost"
                    function = "Sum"
                }
            }
        }
    } | ConvertTo-Json -Depth 10
    
    $headers = @{
        "Authorization" = "Bearer $Token"
        "Content-Type" = "application/json"
    }
    
    try {
        $response = Invoke-RestMethod -Uri $spendUri -Method POST -Headers $headers -Body $spendBody -ErrorAction Stop
        return $response.properties.rows[0][0]
    } catch {
        Write-Warning "Failed to get current budget spend: $($_.Exception.Message)"
        return 0
    }
}

function Get-AdvisorCostRecommendations {
    param(
        [string]$SubscriptionId,
        [string]$Token
    )
    
    # Try multiple Advisor API approaches as availability and formatting varies significantly
    $advisorEndpoints = @(
        @{
            Uri = "https://management.azure.com/subscriptions/$SubscriptionId/providers/Microsoft.Advisor/recommendations?api-version=2020-01-01"
            ApiVersion = "2020-01-01-all"
            Description = "Get all recommendations without filter"
        },
        @{
            Uri = "https://management.azure.com/subscriptions/$SubscriptionId/providers/Microsoft.Advisor/recommendations?api-version=2017-04-19"
            ApiVersion = "2017-04-19-all"
            Description = "Legacy API - all recommendations"
        },
        @{
            Uri = "https://management.azure.com/subscriptions/$SubscriptionId/providers/Microsoft.Advisor/generateRecommendations?api-version=2020-01-01"
            ApiVersion = "2020-01-01-generate"
            Description = "Generate fresh recommendations"
            Method = "POST"
        }
    )
    
    $headers = @{
        "Authorization" = "Bearer $Token"
        "Content-Type" = "application/json"
    }
    
    foreach ($endpoint in $advisorEndpoints) {
        try {
            Write-Output "Trying Advisor API: $($endpoint.Description) (version $($endpoint.ApiVersion))"
            
            $method = if ($endpoint.Method) { $endpoint.Method } else { "GET" }
            $body = if ($method -eq "POST") { "{}" } else { $null }
            
            # Use Invoke-WebRequest for better error handling
            if ($body) {
                $response = Invoke-RestMethod -Uri $endpoint.Uri -Method $method -Headers $headers -Body $body -ErrorAction Stop
            } else {
                $response = Invoke-RestMethod -Uri $endpoint.Uri -Method $method -Headers $headers -ErrorAction Stop
            }
            
            # Handle generate recommendations endpoint (returns operation status)
            if ($endpoint.ApiVersion -eq "2020-01-01-generate") {
                Write-Output "Recommendation generation initiated. Waiting before checking recommendations..."
                Start-Sleep -Seconds 30
                
                # Now try to get the recommendations
                $getUri = "https://management.azure.com/subscriptions/$SubscriptionId/providers/Microsoft.Advisor/recommendations?api-version=2020-01-01"
                $response = Invoke-RestMethod -Uri $getUri -Method GET -Headers $headers -ErrorAction Stop
            }
            
            if ($response.value -and $response.value.Count -gt 0) {
                Write-Output "Found $($response.value.Count) total recommendations using $($endpoint.Description)"
                
                # Filter for cost recommendations
                $costRecommendations = $response.value | Where-Object { 
                    $_.properties.category -eq "Cost" -or 
                    $_.properties.category -eq "cost" -or
                    ($_.properties.shortDescription.problem -and $_.properties.shortDescription.problem -match "cost|saving|spend|bill") -or
                    ($_.properties.impact -and $_.properties.impact -match "cost|saving")
                }
                
                if ($costRecommendations -and $costRecommendations.Count -gt 0) {
                    Write-Output "Found $($costRecommendations.Count) cost-related recommendations"
                    return $costRecommendations | ForEach-Object {
                        $savingsAmount = 0
                        
                        # Try multiple ways to extract savings amount
                        if ($_.properties.extendedProperties.savingsAmount) {
                            try { $savingsAmount = [double]$_.properties.extendedProperties.savingsAmount } catch { $savingsAmount = 0 }
                        } elseif ($_.properties.extendedProperties.annualSavingsAmount) {
                            try { $savingsAmount = [double]$_.properties.extendedProperties.annualSavingsAmount } catch { $savingsAmount = 0 }
                        } elseif ($_.properties.extendedProperties.monthlySavings) {
                            try { $savingsAmount = [double]$_.properties.extendedProperties.monthlySavings * 12 } catch { $savingsAmount = 0 }
                        }
                        
                        @{
                            RecommendationType = if ($_.properties.shortDescription.problem) { $_.properties.shortDescription.problem } else { "Cost Optimization" }
                            ResourceId = if ($_.properties.resourceMetadata.resourceId) { $_.properties.resourceMetadata.resourceId } else { "N/A" }
                            ResourceName = if ($_.properties.resourceMetadata.resourceId) { ($_.properties.resourceMetadata.resourceId -split '/')[-1] } else { "N/A" }
                            Impact = if ($_.properties.impact) { $_.properties.impact } else { "Unknown" }
                            PotentialSavings = $savingsAmount
                            Description = if ($_.properties.shortDescription.solution) { $_.properties.shortDescription.solution } else { "Cost optimization recommendation" }
                            ActionType = if ($_.properties.category) { $_.properties.category } else { "Cost" }
                            RecommendationId = if ($_.id) { $_.id } else { "N/A" }
                        }
                    }
                } else {
                    Write-Output "No cost recommendations found after filtering with $($endpoint.Description)"
                }
            } else {
                Write-Output "No recommendations returned from $($endpoint.Description)"
            }
        } catch {
            $statusCode = $null
            $errorMessage = $_.Exception.Message
            
            # Extract HTTP status code
            if ($_.Exception.Response) {
                $statusCode = [int]$_.Exception.Response.StatusCode
            } elseif ($errorMessage -match "(\d{3})") {
                $statusCode = [int]$matches[1]
            }
            
            Write-Output "Advisor API $($endpoint.Description) failed with status $statusCode`: $errorMessage"
            
            # Handle specific error conditions with detailed logging
            switch ($statusCode) {
                400 {
                    Write-Output "Bad Request (400) for $($endpoint.Description) - API format not supported or invalid parameters"
                    # Continue to next endpoint
                }
                401 {
                    Write-Warning "Authentication failed (401) for Advisor API - check managed identity token"
                    # Don't continue if auth fails
                    break
                }
                403 {
                    Write-Warning "Access denied (403) for Advisor API - check Reader role assignment"
                    # Continue to try other endpoints
                }
                404 {
                    Write-Output "Advisor service not found (404) for $($endpoint.Description) - trying alternative approach"
                    # Continue to next endpoint
                }
                429 {
                    Write-Warning "Rate limited (429) for Advisor API - waiting before retry"
                    Start-Sleep -Seconds 60
                    # Continue to next endpoint
                }
                default {
                    Write-Output "Unexpected error ($statusCode) for $($endpoint.Description) - trying alternative approach"
                    # Continue to next endpoint
                }
            }
        }
    }
    
    # If all endpoints fail, try the PowerShell cmdlet approach as a fallback
    try {
        Write-Output "Trying PowerShell Get-AzAdvisorRecommendation cmdlet as fallback"
        $recommendations = Get-AzAdvisorRecommendation -Category Cost -ErrorAction SilentlyContinue
        
        if ($recommendations -and $recommendations.Count -gt 0) {
            Write-Output "Found $($recommendations.Count) cost recommendations using PowerShell cmdlet"
            return $recommendations | ForEach-Object {
                @{
                    RecommendationType = if ($_.ShortDescription.Problem) { $_.ShortDescription.Problem } else { "Cost Optimization" }
                    ResourceId = if ($_.ResourceId) { $_.ResourceId } else { "N/A" }
                    ResourceName = if ($_.ResourceId) { ($_.ResourceId -split '/')[-1] } else { "N/A" }
                    Impact = if ($_.Impact) { $_.Impact } else { "Unknown" }
                    PotentialSavings = if ($_.ExtendedProperties.savingsAmount) { [double]$_.ExtendedProperties.savingsAmount } else { 0 }
                    Description = if ($_.ShortDescription.Solution) { $_.ShortDescription.Solution } else { "Cost optimization recommendation" }
                    ActionType = "Cost"
                    RecommendationId = if ($_.Id) { $_.Id } else { "N/A" }
                }
            }
        } else {
            Write-Output "No cost recommendations found using PowerShell cmdlet"
        }
    } catch {
        Write-Output "PowerShell cmdlet fallback also failed: $($_.Exception.Message)"
    }
    
    Write-Output "No advisor recommendations available for subscription $SubscriptionId using any method - this may be normal for certain subscription types or new subscriptions"
    return @()
}

# Main execution
try {
    Write-Output "Starting enhanced cost data collection for $CollectionDate"
    Write-Output "Options: Forecasting=$IncludeForecasting, Budgets=$IncludeBudgets, Advisor=$IncludeAdvisor"
    
    # Connect to Azure using Managed Identity with retry logic
    $maxRetries = 3
    $retryCount = 0
    $connected = $false
    
    while (-not $connected -and $retryCount -lt $maxRetries) {
        try {
            $AzureContext = (Connect-AzAccount -Identity).Context
            $connected = $true
            Write-Output "Successfully connected to Azure with Managed Identity"
        } catch {
            $retryCount++
            Write-Warning "Failed to connect to Azure (attempt $retryCount of $maxRetries): $($_.Exception.Message)"
            if ($retryCount -lt $maxRetries) {
                Start-Sleep -Seconds (5 * $retryCount)
            }
        }
    }
    
    if (-not $connected) {
        throw "Failed to connect to Azure after $maxRetries attempts"
    }
    
    # Get target subscriptions from automation variable
    try {
        $targetSubscriptions = Get-AutomationVariable -Name "TARGET_SUBSCRIPTION_IDS"
        if (-not $targetSubscriptions) {
            throw "TARGET_SUBSCRIPTION_IDS automation variable is empty or not found"
        }
        $subscriptionIds = $targetSubscriptions -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne "" }
        
        if ($subscriptionIds.Count -eq 0) {
            throw "No valid subscription IDs found in TARGET_SUBSCRIPTION_IDS"
        }
    } catch {
        Write-Error "Failed to get target subscriptions: $($_.Exception.Message)"
        throw
    }
    
    # Get workspace credentials from automation variables
    try {
        $workspaceId = Get-AutomationVariable -Name "LOG_ANALYTICS_WORKSPACE_ID"
        $workspaceKey = Get-AutomationVariable -Name "LOG_ANALYTICS_WORKSPACE_KEY"
        
        if (-not $workspaceId -or -not $workspaceKey) {
            throw "Log Analytics workspace credentials not found or empty"
        }
    } catch {
        Write-Error "Failed to get Log Analytics credentials: $($_.Exception.Message)"
        throw
    }
    
    Write-Output "Processing $($subscriptionIds.Count) subscriptions"
    
    # Define required tags for cost allocation
    $requiredTags = @('CostCenter', 'Project', 'Environment', 'Owner', 'Department')
    
    # Add rate limiting between subscription processing
    $subscriptionDelaySeconds = 30  # Increased from 15 to 30 seconds for better API stability
    
    for ($i = 0; $i -lt $subscriptionIds.Count; $i++) {
        $subscriptionId = $subscriptionIds[$i].Trim()
        Write-Output "Processing subscription $($i + 1) of $($subscriptionIds.Count): $subscriptionId"
        
        # Add delay between subscriptions (except for the first one)
        if ($i -gt 0) {
            Write-Output "Waiting $subscriptionDelaySeconds seconds before processing next subscription..."
            Start-Sleep -Seconds $subscriptionDelaySeconds
        }
        
        try {
            # Set subscription context with verification
            $context = Set-AzContext -SubscriptionId $subscriptionId -Force
            Write-Output "Set context to subscription: $($context.Subscription.Name) ($subscriptionId)"
            
            # Enhanced subscription validation and API testing
            try {
                # Get fresh token for each subscription
                $context = Get-AzContext
                $token = [Microsoft.Azure.Commands.Common.Authentication.AzureSession]::Instance.AuthenticationFactory.Authenticate($context.Account, $context.Environment, $context.Tenant.Id, $null, "Never", $null, "https://management.azure.com/").AccessToken
                
                # Check subscription details first
                $subscription = Get-AzSubscription -SubscriptionId $subscriptionId
                Write-Output "Subscription details: Name='$($subscription.Name)', State='$($subscription.State)', Type='$($subscription.SubscriptionPolicies.SubscriptionType)'"
                
                # Skip disabled subscriptions
                if ($subscription.State -ne "Enabled") {
                    Write-Warning "Subscription $subscriptionId is in state '$($subscription.State)' - skipping"
                    continue
                }
                
                # Test Cost Management API access with minimal query
                $testQuery = @{
                    type = "Usage"
                    timeframe = "MonthToDate"
                    dataset = @{
                        granularity = "None"
                        aggregation = @{
                            totalCost = @{
                                name = "Cost"
                                function = "Sum"
                            }
                        }
                    }
                } | ConvertTo-Json -Depth 5
                
                $testUri = "https://management.azure.com/subscriptions/$subscriptionId/providers/Microsoft.CostManagement/query?api-version=2021-10-01"
                Write-Output "Testing Cost Management API access for subscription $subscriptionId"
                
                $testHeaders = @{
                    "Authorization" = "Bearer $token"
                    "Content-Type" = "application/json"
                }
                
                # Use shorter timeout and better error handling
                try {
                    $testResponse = Invoke-RestMethod -Uri $testUri -Method POST -Headers $testHeaders -Body $testQuery -TimeoutSec 15 -ErrorAction Stop
                    Write-Output "Cost Management API access confirmed - subscription has cost data available"
                } catch {
                    $errorDetails = $_.Exception.Message
                    $statusCode = $null
                    
                    # Extract HTTP status code
                    if ($_.Exception.Response) {
                        $statusCode = [int]$_.Exception.Response.StatusCode
                    } elseif ($errorDetails -match "(\d{3})") {
                        $statusCode = [int]$matches[1]
                    }
                    
                    # Handle specific error conditions
                    switch ($statusCode) {
                        400 {
                            Write-Warning "Subscription $subscriptionId doesn't support Cost Management API (400 Bad Request) - likely unsupported subscription type"
                            Write-Output "Skipping subscription due to unsupported subscription type"
                            continue
                        }
                        401 {
                            Write-Warning "Authentication failed for subscription $subscriptionId (401 Unauthorized)"
                            Write-Output "Skipping subscription due to authentication issues"
                            continue
                        }
                        403 {
                            Write-Warning "Access denied for subscription $subscriptionId (403 Forbidden) - check Cost Management Reader permissions"
                            Write-Output "Skipping subscription due to insufficient permissions"
                            continue
                        }
                        404 {
                            Write-Warning "Cost Management not available for subscription $subscriptionId (404 Not Found)"
                            Write-Output "Skipping subscription due to Cost Management not being available"
                            continue
                        }
                        default {
                            Write-Warning "Cost Management API test failed for subscription $subscriptionId (HTTP $statusCode): $errorDetails"
                            Write-Output "Skipping subscription due to API access issues"
                            continue
                        }
                    }
                }
                
            } catch {
                Write-Warning "Failed to validate subscription $subscriptionId`: $($_.Exception.Message)"
                Write-Output "Skipping subscription due to validation errors"
                continue
            }
            
            # Get cost data for the last 30 days with improved compatibility
            $endDate = Get-Date $CollectionDate
            $startDate = $endDate.AddDays(-30)
            
            # Enhanced: Use more compatible Cost Management API format
            $subscriptionScope = "/subscriptions/$subscriptionId"
            $apiVersion = "2021-10-01"  # Use more stable API version
            
            # Use simplified, well-supported request format for better compatibility
            $requestBody = @{
                type = "Usage"  # Changed from ActualCost to Usage for better compatibility
                timeframe = "Custom"
                timePeriod = @{
                    from = $startDate.ToString("yyyy-MM-dd")
                    to = $endDate.ToString("yyyy-MM-dd")
                }
                dataset = @{
                    granularity = "Daily"
                    aggregation = @{
                        totalCost = @{
                            name = "Cost"
                            function = "Sum"
                        }
                    }
                    grouping = @(
                        @{
                            type = "Dimension"
                            name = "ResourceGroup"  # Changed from ResourceGroupName to ResourceGroup
                        },
                        @{
                            type = "Dimension"
                            name = "ServiceName"
                        }
                    )
                }
            } | ConvertTo-Json -Depth 8  # Reduced depth for compatibility
            
            # Get access token for Cost Management API
            $context = Get-AzContext
            $token = [Microsoft.Azure.Commands.Common.Authentication.AzureSession]::Instance.AuthenticationFactory.Authenticate($context.Account, $context.Environment, $context.Tenant.Id, $null, "Never", $null, "https://management.azure.com/").AccessToken
            
            # Make the API call with retry logic and exponential backoff
            $uri = "https://management.azure.com$subscriptionScope/providers/Microsoft.CostManagement/query?api-version=$apiVersion"
            $headers = @{
                "Authorization" = "Bearer $token"
                "Content-Type" = "application/json"
            }
            
            # Execute cost query with enhanced retry logic
            $costData = Invoke-CostManagementQuery -Uri $uri -Headers $headers -Body $requestBody -MaxRetries 5
            
            if ($null -eq $costData -or $costData.Count -eq 0) {
                Write-Warning "No cost data available for subscription $subscriptionId. Moving to next subscription."
                continue
            }
            
            Write-Output "Retrieved $($costData.Count) cost records for subscription $subscriptionId"
            
            # Process cost data with enhanced validation and correct API response structure
            # Usage API with 2 grouping dimensions returns: Cost, UsageDate, ResourceGroup, ServiceName, Currency
            $validRecords = 0
            $skippedRecords = 0
            $zeroCostRecords = 0
            $totalCost = 0
            $serviceBreakdown = @{}
            
            foreach ($record in $costData) {
                try {
                    # Enhanced validation - ensure record is array and has correct structure (now expects 5 fields)
                    if ($null -eq $record -or -not ($record -is [array]) -or $record.Count -lt 5) {
                        $skippedRecords++
                        continue
                    }
                    
                    # Validate first field is numeric (cost)
                    $costValue = $record[0]
                    if (-not ($costValue -is [double] -or $costValue -is [int] -or $costValue -is [decimal] -or ($costValue -is [string] -and $costValue -match "^-?\d+(\.\d+)?$"))) {
                        $skippedRecords++
                        continue
                    }
                    
                    # Parse the Usage API response with proper type conversion
                    $cost = [double]$costValue
                    
                    # Parse basic fields first before using them
                    $resourceGroup = if ($record[2]) { [string]$record[2] } else { "Unknown" }
                    $serviceName = if ($record[3]) { [string]$record[3] } else { "Unknown" }
                    $currency = if ($record[4]) { [string]$record[4] } else { "USD" }
                    
                    # Ensure serviceName is not null or empty for tracking
                    if ([string]::IsNullOrWhiteSpace($serviceName)) {
                        $serviceName = "Unknown Service"
                    }
                    
                    # Track cost distribution for better reporting
                    $isZeroCost = ($cost -eq 0)
                    if ($isZeroCost) {
                        $zeroCostRecords++
                    } else {
                        $totalCost += $cost
                    }
                    
                    # Track service breakdown with null safety
                    $serviceKey = $serviceName
                    if (-not $serviceBreakdown.ContainsKey($serviceKey)) {
                        $serviceBreakdown[$serviceKey] = @{ Count = 0; Cost = 0 }
                    }
                    $serviceBreakdown[$serviceKey].Count++
                    $serviceBreakdown[$serviceKey].Cost += $cost
                    
                    # Validate and parse date field (expects YYYYMMDD integer format - Int64 from API)
                    $dateValue = $record[1]
                    try {
                        if ($dateValue -is [int] -or $dateValue -is [int32] -or $dateValue -is [int64] -or $dateValue -is [long]) {
                            # Convert YYYYMMDD integer to datetime
                            $dateString = $dateValue.ToString()
                            if ($dateString.Length -eq 8) {
                                $year = [int]$dateString.Substring(0, 4)
                                $month = [int]$dateString.Substring(4, 2)
                                $day = [int]$dateString.Substring(6, 2)
                                $date = [datetime]::new($year, $month, $day)
                            } else {
                                $skippedRecords++
                                continue
                            }
                        } elseif ($dateValue -is [string]) {
                            # Handle string format as fallback
                            if ($dateValue.Length -eq 8 -and $dateValue -match "^\d{8}$") {
                                $year = [int]$dateValue.Substring(0, 4)
                                $month = [int]$dateValue.Substring(4, 2)
                                $day = [int]$dateValue.Substring(6, 2)
                                $date = [datetime]::new($year, $month, $day)
                            } else {
                                $date = [datetime]::Parse($dateValue)
                            }
                        } elseif ($dateValue -is [datetime]) {
                            $date = $dateValue
                        } else {
                            $skippedRecords++
                            continue
                        }
                    } catch {
                        Write-Warning "Failed to parse date value '$dateValue' of type $($dateValue.GetType().Name)"
                        $skippedRecords++
                        continue
                    }
                    
                    # Skip zero-cost entries only for certain service types to reduce noise, but keep important ones
                    if ($isZeroCost) {
                        # Keep zero-cost records for important services that might indicate provisioned but unused resources
                        $keepZeroCostServices = @(
                            "Virtual Machines",
                            "Storage",
                            "SQL Database", 
                            "App Service",
                            "Azure Kubernetes Service",
                            "Application Gateway",
                            "Load Balancer",
                            "Virtual Network",
                            "Azure Active Directory"
                        )
                        
                        $shouldKeepZeroCost = $false
                        foreach ($service in $keepZeroCostServices) {
                            if ($serviceName -like "*$service*") {
                                $shouldKeepZeroCost = $true
                                break
                            }
                        }
                        
                        if (-not $shouldKeepZeroCost) {
                            $skippedRecords++
                            continue
                        }
                    }
                
                    # Extract additional metadata from available data
                    $resourceName = "N/A" # Will need to be derived from resource group and service
                    $meterCategory = $serviceName # Use ServiceName as MeterCategory since we don't have direct access
                    $resourceType = "Unknown" # Not available in this simplified API response
                    $resourceLocation = "Unknown" # Not available in this simplified API response  
                    $resourceId = "N/A" # Not available in this API response format
                    
                    # Generate a synthetic resource name based on available data
                    if ($serviceName -and $resourceGroup) {
                        $resourceName = "$serviceName-in-$resourceGroup"
                    }
                    
                    # Set defaults for tag data (not available from this API call)
                    $costCenter = $null
                    $project = $null
                    $environment = $null
                    $owner = $null
                    $department = $null
                    
                    # Enhanced tag completeness analysis (all will be null since we don't have tag data)
                    $tagCompleteness = 0
                    $missingTags = @('CostCenter', 'Project', 'Environment', 'Owner', 'Department')
                    
                    # Determine if this is an AVD resource (enhanced logic)
                    $isAVDResource = $false
                    if ($resourceGroup -like "*avd*" -or 
                        $serviceName -match "Windows Virtual Desktop|Azure Virtual Desktop" -or
                        $meterCategory -match "Windows Virtual Desktop|Azure Virtual Desktop" -or
                        $project -like "*AVD*" -or
                        $environment -like "*VDI*") {
                        $isAVDResource = $true
                    }
                    
                    # Prepare enhanced log entry with available data
                    $logEntry = [PSCustomObject]@{
                        TimeGenerated = $date.ToString("yyyy-MM-ddTHH:mm:ssZ")
                        SubscriptionId = $subscriptionId
                        ResourceGroup = $resourceGroup
                        ResourceName = $resourceName
                        ResourceId = $resourceId
                        ResourceType = $resourceType
                        ServiceName = $serviceName
                        MeterCategory = $meterCategory
                        Cost = $cost
                        CostUSD = $cost  # Use same cost value since API returns in subscription currency
                        Currency = $currency
                        Location = $resourceLocation
                        IsAVDResource = $isAVDResource
                        IsZeroCost = $isZeroCost
                        CollectionDate = $CollectionDate
                        # Enhanced tagging fields (set to defaults since not available from this API)
                        CostCenter = "Unallocated"
                        Project = "Unallocated"
                        Environment = "Unknown"
                        Owner = "Unknown"
                        Department = "Unallocated"
                        TagCompleteness = $tagCompleteness
                        MissingTags = ($missingTags -join ";")
                        AllocationStatus = "UnallocatedCost" # Since we don't have tag data
                    }
                    
                    # Send to Log Analytics
                    Send-LogAnalyticsData -WorkspaceId $workspaceId -WorkspaceKey $workspaceKey -LogType "AzureCostData" -DataObject $logEntry
                    $validRecords++
                    
                } catch {
                    Write-Warning "Error processing cost record: $($_.Exception.Message)"
                    $skippedRecords++
                    continue
                }
            }
            
            Write-Output "Processed $validRecords valid cost records for subscription $subscriptionId (skipped $skippedRecords invalid records)"
            Write-Output "Cost breakdown: $zeroCostRecords zero-cost records, $($validRecords - $zeroCostRecords) non-zero records, total cost: $($totalCost.ToString('C2'))"
            
            # Show top 5 services by cost
            $topServices = $serviceBreakdown.GetEnumerator() | Sort-Object { $_.Value.Cost } -Descending | Select-Object -First 5
            Write-Output "Top services by cost:"
            foreach ($service in $topServices) {
                Write-Output "  $($service.Key): $($service.Value.Count) records, $($service.Value.Cost.ToString('C2'))"
            }
            
            # Collect Forecast Data
            if ($IncludeForecasting) {
                Write-Output "Collecting forecast data for subscription $subscriptionId"
                $forecastData = Get-CostForecast -SubscriptionId $subscriptionId -Token $token
                
                foreach ($forecast in $forecastData) {
                    $forecastEntry = [PSCustomObject]@{
                        TimeGenerated = (Get-Date).ToString("yyyy-MM-ddTHH:mm:ssZ")
                        SubscriptionId = $subscriptionId
                        ForecastDate = $forecast.Date
                        ForecastedCost = $forecast.Cost
                        ConfidenceLevelLow = $forecast.ConfidenceLevelLow
                        ConfidenceLevelHigh = $forecast.ConfidenceLevelHigh
                        ForecastType = "30Day"
                        CollectionDate = $CollectionDate
                    }
                    
                    Send-LogAnalyticsData -WorkspaceId $workspaceId -WorkspaceKey $workspaceKey -LogType "AzureCostForecast" -DataObject $forecastEntry
                }
            }
            
            # Collect Budget Data
            if ($IncludeBudgets) {
                Write-Output "Collecting budget data for subscription $subscriptionId"
                try {
                    $budgets = Get-AzConsumptionBudget -ErrorAction SilentlyContinue
                    
                    if ($budgets -and $budgets.Count -gt 0) {
                        foreach ($budget in $budgets) {
                            $currentSpend = Get-CurrentBudgetSpend -Budget $budget -Token $token
                            $burnRate = if ($budget.Amount -gt 0) { ($currentSpend / $budget.Amount) * 100 } else { 0 }
                            
                            $budgetEntry = [PSCustomObject]@{
                                TimeGenerated = (Get-Date).ToString("yyyy-MM-ddTHH:mm:ssZ")
                                SubscriptionId = $subscriptionId
                                BudgetName = $budget.Name
                                BudgetAmount = $budget.Amount
                                CurrentSpend = $currentSpend
                                BurnRatePercentage = $burnRate
                                TimeRemaining = $budget.TimePeriod.EndDate - (Get-Date)
                                ProjectedOverspend = if ($burnRate -gt 100) { $currentSpend - $budget.Amount } else { 0 }
                                AlertThreshold = if ($budget.Notifications -and $budget.Notifications.Count -gt 0) { $budget.Notifications[0].Threshold } else { 0 }
                                CollectionDate = $CollectionDate
                            }
                            
                            Send-LogAnalyticsData -WorkspaceId $workspaceId -WorkspaceKey $workspaceKey -LogType "AzureBudgetTracking" -DataObject $budgetEntry
                        }
                        Write-Output "Processed $($budgets.Count) budgets for subscription $subscriptionId"
                    } else {
                        Write-Output "No budgets found for subscription $subscriptionId"
                    }
                } catch {
                    Write-Warning "Failed to collect budget data for subscription $subscriptionId`: $($_.Exception.Message)"
                    # Continue processing other data types even if budgets fail
                }
            }
            
            # Collect Advisor Recommendations
            if ($IncludeAdvisor) {
                Write-Output "Collecting Azure Advisor cost recommendations for subscription $subscriptionId"
                try {
                    $recommendations = Get-AdvisorCostRecommendations -SubscriptionId $subscriptionId -Token $token
                    
                    if ($recommendations -and $recommendations.Count -gt 0) {
                        foreach ($recommendation in $recommendations) {
                            $advisorEntry = [PSCustomObject]@{
                                TimeGenerated = (Get-Date).ToString("yyyy-MM-ddTHH:mm:ssZ")
                                SubscriptionId = $subscriptionId
                                RecommendationType = $recommendation.RecommendationType
                                ResourceId = $recommendation.ResourceId
                                ResourceName = $recommendation.ResourceName
                                Impact = $recommendation.Impact
                                PotentialSavings = $recommendation.PotentialSavings
                                RecommendationText = $recommendation.Description
                                ActionType = $recommendation.ActionType
                                CollectionDate = $CollectionDate
                            }
                            
                            Send-LogAnalyticsData -WorkspaceId $workspaceId -WorkspaceKey $workspaceKey -LogType "AzureAdvisorRecommendations" -DataObject $advisorEntry
                        }
                        Write-Output "Processed $($recommendations.Count) advisor recommendations for subscription $subscriptionId"
                    } else {
                        Write-Output "No advisor cost recommendations found for subscription $subscriptionId (this may be normal)"
                    }
                } catch {
                    Write-Warning "Failed to collect advisor recommendations for subscription $subscriptionId`: $($_.Exception.Message)"
                    # Continue processing
                }
            }
            
            Write-Output "Completed processing subscription $subscriptionId"
            
        } catch {
            Write-Error "Failed to process subscription $subscriptionId`: $($_.Exception.Message)"
        }
    }
    
    Write-Output "Enhanced cost data collection completed successfully for $($subscriptionIds.Count) subscriptions"
    Write-Output "Data collected: Cost Data, Forecasts=$IncludeForecasting, Budgets=$IncludeBudgets, Advisor=$IncludeAdvisor"
    
} catch {
    Write-Error "Enhanced cost data collection failed: $($_.Exception.Message)"
    throw
}
