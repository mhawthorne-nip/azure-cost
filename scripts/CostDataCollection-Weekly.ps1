# Enhanced Cost Data Collection Runbook for Azure Cost Management
# Version 2.3 - Fixed rate limit tracking and improved error handling
# 
# Key fixes implemented:
# - Enhanced record validation to prevent processing debug output as cost data
# - Improved numeric validation for cost values to ensure data integrity
# - Added comprehensive error handling for budget collection API errors
# - Better handling of subscription types that don't support certain APIs
# - Reduced debug output contamination in cost records
# - Added record counting for better monitoring and troubleshooting
# - FIXED: Rate limit tracking now properly counts 429 errors across all API calls
# - Enhanced rate limit monitoring and reporting in execution summary
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
        [int]$MaxRetries = 5,  # Reduced from 7 to 5 for faster processing
        [int]$BaseDelaySeconds = 30,  # Reduced base delay to 30 seconds
        [ref]$RateLimitHitCount  # Reference to track rate limit hits
    )
    
    $retryCount = 0
    $costData = $null
    
    while ($retryCount -lt $MaxRetries -and $null -eq $costData) {
        try {
            Write-Output "Attempting Cost Management API call (attempt $($retryCount + 1) of $MaxRetries)"
            
            # Add pre-call delay for rate limiting (except first attempt)
            if ($retryCount -gt 0) {
                # Progressive delays with jitter for rate limiting
                $baseDelay = $BaseDelaySeconds * [Math]::Pow(1.5, $retryCount - 1)
                $jitter = Get-Random -Minimum 5 -Maximum 15
                $totalPreDelay = [Math]::Min($baseDelay + $jitter, 180)  # Cap at 3 minutes instead of 5
                Write-Output "Pre-call rate limiting delay: $totalPreDelay seconds"
                Start-Sleep -Seconds $totalPreDelay
            }
            
            # Set longer timeout for Cost Management API
            $response = Invoke-RestMethod -Uri $Uri -Method POST -Headers $Headers -Body $Body -TimeoutSec 120 -ErrorAction Stop
            
            # Enhanced response validation and debugging
            if ($response -and $response.properties) {
                Write-Output "API response received with properties structure"
                
                if ($response.properties.rows) {
                    $costData = $response.properties.rows
                    Write-Output "Successfully retrieved $($costData.Count) cost records from response.properties.rows"
                    
                    # Enhanced debugging for first record structure
                    if ($costData.Count -gt 0) {
                        $firstRecord = $costData[0]
                        Write-Output "First record structure: Type=$($firstRecord.GetType().Name), Count=$($firstRecord.Count)"
                        
                        # Log sample of first few records for debugging
                        for ($i = 0; $i -lt [Math]::Min(3, $costData.Count); $i++) {
                            $sampleRecord = $costData[$i]
                            if ($sampleRecord -is [array] -and $sampleRecord.Count -ge 3) {
                                Write-Output "Sample record $i`: Cost=$($sampleRecord[0]), Date=$($sampleRecord[1]), Service=$($sampleRecord[2])"
                            } else {
                                Write-Output "Sample record $i`: Type=$($sampleRecord.GetType().Name), Value='$sampleRecord'"
                            }
                        }
                        
                        # Filter out any non-array records and debug information
                        $validCostData = @()
                        foreach ($record in $costData) {
                            if ($record -is [array] -and $record.Count -ge 4) {
                                $validCostData += ,$record  # Note the comma operator to preserve array structure
                            } else {
                                Write-Output "Filtering out invalid record: Type=$($record.GetType().Name), Value='$record'"
                            }
                        }
                        
                        $costData = $validCostData
                        Write-Output "After filtering: $($costData.Count) valid array records remain"
                        
                        if ($costData.Count -gt 0) {
                            Write-Output "Record validation passed: First record has $($costData[0].Count) fields"
                            # Log field structure for the first valid record
                            for ($i = 0; $i -lt $costData[0].Count; $i++) {
                                $fieldValue = $costData[0][$i]
                                Write-Output "  Field $i`: $fieldValue (Type: $($fieldValue.GetType().Name))"
                            }
                        }
                    }
                    return $costData
                } elseif ($response.properties.nextLink) {
                    Write-Warning "API response contains nextLink but no rows - pagination issue detected"
                    return @()
                } else {
                    Write-Warning "API response properties missing 'rows' field"
                    Write-Output "Available properties: $($response.properties | Get-Member -MemberType Properties | Select-Object -ExpandProperty Name -join ', ')"
                    return @()
                }
            } else {
                Write-Warning "API response missing expected data structure - no properties field"
                if ($response) {
                    Write-Output "Response structure: $($response | Get-Member -MemberType Properties | Select-Object -ExpandProperty Name -join ', ')"
                }
                return @()  # Return empty array instead of null
            }
        } catch {
            $retryCount++
            $errorMessage = $_.Exception.Message
            $statusCode = $null
            
            # Extract status code from various error formats
            if ($_.Exception.Response) {
                $statusCode = [int]$_.Exception.Response.StatusCode
            } elseif ($errorMessage -match "(\d{3})") {
                $statusCode = [int]$matches[1]
            }
            
            Write-Warning "API call failed (attempt $retryCount): $errorMessage"
            
            # Handle specific error conditions with enhanced rate limiting
            if ($statusCode -eq 400) {
                Write-Warning "Bad Request (400) - Request format may be invalid or subscription type unsupported."
                Write-Warning "Error details: $errorMessage"
                # For 400 errors, don't retry as it's likely a structural issue
                Write-Error "Persistent 400 error - request format invalid or unsupported subscription type for subscription"
                break
            } elseif ($statusCode -eq 429 -or $errorMessage -like "*Too Many Requests*") {
                # INCREMENT RATE LIMIT COUNTER - This was missing before!
                if ($RateLimitHitCount.Value -ne $null) {
                    $RateLimitHitCount.Value++
                    Write-Warning "Rate limit exceeded (HTTP 429) - implementing aggressive backoff strategy (hit #$($RateLimitHitCount.Value))"
                } else {
                    Write-Warning "Rate limit exceeded (HTTP 429) - implementing aggressive backoff strategy"
                }
                
                if ($retryCount -lt $MaxRetries) {
                    # More conservative exponential backoff for 429 errors
                    $rateLimitDelay = $BaseDelaySeconds * [Math]::Pow(1.8, $retryCount)  # Less aggressive than 2
                    $jitter = Get-Random -Minimum 10 -Maximum 30
                    $totalDelay = [Math]::Min($rateLimitDelay + $jitter, 300)  # Cap at 5 minutes
                    
                    Write-Output "Rate limit backoff: Waiting $totalDelay seconds before retry (attempt $retryCount of $MaxRetries)"
                    Write-Output "Recommendation: Consider reducing concurrent subscriptions or increasing delays between calls"
                    
                    # Add checkpoint logging for long delays
                    if ($totalDelay -gt 60) {  # Reduced threshold from 120 to 60
                        $checkpoints = [Math]::Floor($totalDelay / 30)  # 30-second checkpoints instead of 60
                        for ($i = 1; $i -le $checkpoints; $i++) {
                            Start-Sleep -Seconds 30
                            $remaining = $totalDelay - ($i * 30)
                            if ($remaining -gt 0) {
                                Write-Output "Rate limit backoff in progress: $remaining seconds remaining..."
                            }
                        }
                        $finalDelay = $totalDelay % 30
                        if ($finalDelay -gt 0) {
                            Start-Sleep -Seconds $finalDelay
                        }
                    } else {
                        Start-Sleep -Seconds $totalDelay
                    }
                } else {
                    Write-Error "Maximum retries exceeded for rate-limited API call. Consider reducing API call frequency."
                    break
                }
            } elseif ($statusCode -eq 401 -or $statusCode -eq 403) {
                Write-Error "Authentication/Authorization error. Check managed identity permissions for Cost Management Reader role."
                break
            } elseif ($statusCode -eq 404) {
                Write-Warning "No cost data found or subscription not accessible. Skipping."
                return @()  # Return empty array for 404
            } elseif ($statusCode -eq 503 -or $statusCode -eq 502 -or $statusCode -eq 500) {
                # Server errors - implement backoff but shorter than rate limits
                if ($retryCount -lt $MaxRetries) {
                    $serverErrorDelay = 30 * [Math]::Pow(1.5, $retryCount - 1)
                    $jitter = Get-Random -Minimum 5 -Maximum 15
                    $totalDelay = [Math]::Min($serverErrorDelay + $jitter, 180)  # Cap at 3 minutes
                    Write-Output "Server error ($statusCode). Waiting $totalDelay seconds before retry..."
                    Start-Sleep -Seconds $totalDelay
                }
            } else {
                if ($retryCount -lt $MaxRetries) {
                    $delaySeconds = 10 * [Math]::Pow(1.8, $retryCount - 1)
                    $jitter = Get-Random -Minimum 2 -Maximum 8
                    $totalDelay = [Math]::Min($delaySeconds + $jitter, 120)  # Cap at 2 minutes
                    Write-Output "Transient error. Waiting $totalDelay seconds before retry..."
                    Start-Sleep -Seconds $totalDelay
                }
            }
        }
    }
    
    # Return empty array if all retries failed
    Write-Warning "All retry attempts failed for Cost Management API call after $MaxRetries attempts"
    Write-Output "Consider increasing delays between subscription processing or reducing concurrent operations"
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
        [string]$Token,
        [ref]$RateLimitHitCount  # Add rate limit tracking
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
    
    $maxRetries = 3
    $retryCount = 0
    
    while ($retryCount -lt $maxRetries) {
        try {
            $response = Invoke-RestMethod -Uri $forecastUri -Method POST -Headers $headers -Body $forecastBody -TimeoutSec 60 -ErrorAction Stop
            return $response.properties.rows | ForEach-Object {
                @{
                    Date = $_[0]
                    Cost = $_[1]
                    ConfidenceLevelLow = $_[2]
                    ConfidenceLevelHigh = $_[3]
                }
            }
        } catch {
            $retryCount++
            $errorMessage = $_.Exception.Message
            $statusCode = $null
            
            if ($_.Exception.Response) {
                $statusCode = [int]$_.Exception.Response.StatusCode
            }
            
            Write-Warning "Failed to get forecast data (attempt $retryCount): $errorMessage"
            
            if ($statusCode -eq 429 -and $retryCount -lt $maxRetries) {
                # Track rate limit hit
                if ($RateLimitHitCount.Value -ne $null) {
                    $RateLimitHitCount.Value++
                    Write-Warning "Rate limit hit during forecast query (hit #$($RateLimitHitCount.Value))"
                }
                
                $delay = 30 * [Math]::Pow(2, $retryCount - 1)
                Write-Output "Rate limited during forecast. Waiting $delay seconds..."
                Start-Sleep -Seconds $delay
            } elseif ($retryCount -lt $maxRetries) {
                Start-Sleep -Seconds (5 * $retryCount)
            }
        }
    }
    
    Write-Warning "Failed to get forecast data after $maxRetries attempts"
    return @()
}

function Get-CurrentBudgetSpend {
    param(
        [object]$Budget,
        [string]$Token,
        [ref]$RateLimitHitCount  # Add rate limit tracking
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
    
    $maxRetries = 3
    $retryCount = 0
    
    while ($retryCount -lt $maxRetries) {
        try {
            $response = Invoke-RestMethod -Uri $spendUri -Method POST -Headers $headers -Body $spendBody -TimeoutSec 60 -ErrorAction Stop
            if ($response.properties.rows -and $response.properties.rows.Count -gt 0) {
                return $response.properties.rows[0][0]
            } else {
                return 0
            }
        } catch {
            $retryCount++
            $errorMessage = $_.Exception.Message
            $statusCode = $null
            
            if ($_.Exception.Response) {
                $statusCode = [int]$_.Exception.Response.StatusCode
            }
            
            Write-Warning "Failed to get current budget spend (attempt $retryCount): $errorMessage"
            
            if ($statusCode -eq 429 -and $retryCount -lt $maxRetries) {
                # Track rate limit hit
                if ($RateLimitHitCount.Value -ne $null) {
                    $RateLimitHitCount.Value++
                    Write-Warning "Rate limit hit during budget spend query (hit #$($RateLimitHitCount.Value))"
                }
                
                $delay = 30 * [Math]::Pow(2, $retryCount - 1)
                Write-Output "Rate limited during budget spend query. Waiting $delay seconds..."
                Start-Sleep -Seconds $delay
            } elseif ($retryCount -lt $maxRetries) {
                Start-Sleep -Seconds (5 * $retryCount)
            }
        }
    }
    
    Write-Warning "Failed to get current budget spend after $maxRetries attempts"
    return 0
}

function Get-AdvisorCostRecommendations {
    param(
        [string]$SubscriptionId,
        [string]$Token,
        [ref]$RateLimitHitCount  # Add rate limit tracking
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
                    # Track rate limit hit
                    if ($RateLimitHitCount.Value -ne $null) {
                        $RateLimitHitCount.Value++
                        Write-Warning "Rate limited (429) for Advisor API - waiting before retry (hit #$($RateLimitHitCount.Value))"
                    } else {
                        Write-Warning "Rate limited (429) for Advisor API - waiting before retry"
                    }
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
    
    Write-Output "Processing $($subscriptionIds.Count) subscriptions with smart scheduling"
    
    # High-volume subscriptions that should be processed less frequently
    $highVolumeSubscriptions = @(
        "77bc541c-d229-4ff3-81c1-928accbff379",  # NIPAzure(Converted to EA) - 9890+ records
        "e653ba88-fc91-42f4-b22b-c35e36b00835",  # NIP Corp Dev - 3409+ records
        "957c5ab7-da27-42f3-98dc-00baf065261a"   # Visual Studio Enterprise - 2403+ records
    )
    
    # Process high-volume subscriptions every other week to reduce load while ensuring regular processing
    $weekOfYear = (Get-Date $CollectionDate).DayOfYear / 7
    $shouldProcessHighVolume = ([math]::Floor($weekOfYear) % 2 -eq 0)
    
    if (-not $shouldProcessHighVolume) {
        Write-Output "This is not a high-volume processing week (week $([math]::Floor($weekOfYear))). Skipping high-volume subscriptions to reduce load."
        $subscriptionIds = $subscriptionIds | Where-Object { $_ -notin $highVolumeSubscriptions }
        Write-Output "Reduced to $($subscriptionIds.Count) subscriptions for this week's run"
    } else {
        Write-Output "Processing all subscriptions including high-volume ones (week $([math]::Floor($weekOfYear)))"
    }
    
    # Define required tags for cost allocation
    $requiredTags = @('CostCenter', 'Project', 'Environment', 'Owner', 'Department')
    
    # Optimized rate limiting for efficiency while avoiding 429 errors
    $subscriptionDelaySeconds = 30  # Increased from 15 to 30 seconds for better rate limiting
    $apiCallDelaySeconds = 10       # Increased from 5 to 10 seconds for better spacing
    
    # Track overall execution time and API call frequency
    $scriptStartTime = Get-Date
    $totalApiCalls = 0
    $rateLimitHits = 0
    
    for ($i = 0; $i -lt $subscriptionIds.Count; $i++) {
        $subscriptionId = $subscriptionIds[$i].Trim()
        Write-Output "Processing subscription $($i + 1) of $($subscriptionIds.Count): $subscriptionId"
        
        # Add enhanced delay between subscriptions with progress tracking
        if ($i -gt 0) {
            Write-Output "Rate limiting: Waiting $subscriptionDelaySeconds seconds before processing next subscription..."
            Write-Output "Progress: Subscription $($i + 1) of $($subscriptionIds.Count) | API calls made: $totalApiCalls | Rate limit hits: $rateLimitHits"
            
            # Progressive checkpoint logging for long delays
            if ($subscriptionDelaySeconds -gt 60) {
                $checkpoints = [Math]::Floor($subscriptionDelaySeconds / 30)
                for ($j = 1; $j -le $checkpoints; $j++) {
                    Start-Sleep -Seconds 30
                    $remaining = $subscriptionDelaySeconds - ($j * 30)
                    if ($remaining -gt 0) {
                        Write-Output "Inter-subscription delay: $remaining seconds remaining..."
                    }
                }
                $finalDelay = $subscriptionDelaySeconds % 30
                if ($finalDelay -gt 0) {
                    Start-Sleep -Seconds $finalDelay
                }
            } else {
                Start-Sleep -Seconds $subscriptionDelaySeconds
            }
        }
        
        try {
            # Set subscription context with verification
            $context = Set-AzContext -SubscriptionId $subscriptionId -Force
            $subscriptionName = $context.Subscription.Name
            Write-Output "Set context to subscription: $subscriptionName ($subscriptionId)"
            
            # Enhanced subscription validation and API testing
            try {
                # Get fresh token for each subscription
                $context = Get-AzContext
                $token = [Microsoft.Azure.Commands.Common.Authentication.AzureSession]::Instance.AuthenticationFactory.Authenticate($context.Account, $context.Environment, $context.Tenant.Id, $null, "Never", $null, "https://management.azure.com/").AccessToken
                
                # Check subscription details first
                $subscription = Get-AzSubscription -SubscriptionId $subscriptionId
                
                # Enhanced subscription type detection using available properties
                $subscriptionType = "Unknown"
                $quotaId = "Unknown"
                
                # The subscription type is typically indicated by the QuotaId in SubscriptionPolicies
                if ($subscription.SubscriptionPolicies -and $subscription.SubscriptionPolicies.QuotaId) {
                    $quotaId = $subscription.SubscriptionPolicies.QuotaId
                    
                    # Map common QuotaId patterns to readable subscription types
                    switch -Regex ($quotaId) {
                        "MSDNDevTest" { $subscriptionType = "MSDN DevTest" }
                        "PayAsYouGo|PAYG" { $subscriptionType = "Pay-As-You-Go" }
                        "EnterpriseAgreement|EA" { $subscriptionType = "Enterprise Agreement" }
                        "Free" { $subscriptionType = "Free Trial" }
                        "Student" { $subscriptionType = "Azure for Students" }
                        "Sponsored" { $subscriptionType = "Sponsored" }
                        "CSP" { $subscriptionType = "Cloud Solution Provider" }
                        default { $subscriptionType = "QuotaId: $quotaId" }
                    }
                } elseif ($subscription.AuthorizationSource) {
                    $subscriptionType = "AuthSource: $($subscription.AuthorizationSource)"
                } elseif ($subscription.ExtendedProperties -and $subscription.ExtendedProperties.ContainsKey("OfferType")) {
                    $subscriptionType = $subscription.ExtendedProperties["OfferType"]
                }
                
                Write-Output "Subscription details: Name='$($subscription.Name)', State='$($subscription.State)', Type='$subscriptionType' (QuotaId: $quotaId)"
                
                # Skip disabled subscriptions
                if ($subscription.State -ne "Enabled") {
                    Write-Warning "Subscription '$($subscription.Name)' ($subscriptionId) is in state '$($subscription.State)' - skipping"
                    continue
                }
                
                # Test Cost Management API access with minimal query
                $testQuery = @{
                    type = "ActualCost"
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
                Write-Output "Testing Cost Management API access for subscription '$subscriptionName' ($subscriptionId)"
                
                $testHeaders = @{
                    "Authorization" = "Bearer $token"
                    "Content-Type" = "application/json"
                }
                
                # Add rate limiting delay before API test
                Write-Output "Pre-API test delay: $apiCallDelaySeconds seconds"
                Start-Sleep -Seconds $apiCallDelaySeconds
                $totalApiCalls++
                
                # Use shorter timeout and better error handling
                try {
                    $testResponse = Invoke-RestMethod -Uri $testUri -Method POST -Headers $testHeaders -Body $testQuery -TimeoutSec 30 -ErrorAction Stop
                    Write-Output "Cost Management API access confirmed - subscription '$subscriptionName' has cost data available"
                } catch {
                    $errorDetails = $_.Exception.Message
                    $statusCode = $null
                    
                    # Extract HTTP status code
                    if ($_.Exception.Response) {
                        $statusCode = [int]$_.Exception.Response.StatusCode
                    } elseif ($errorDetails -match "(\d{3})") {
                        $statusCode = [int]$matches[1]
                    }
                    
                    # Track rate limit hits for monitoring
                    if ($statusCode -eq 429) {
                        $rateLimitHits++
                        Write-Warning "Rate limit hit during API test for subscription $subscriptionId (hit #$rateLimitHits)"
                    }
                    
                    # Handle specific error conditions
                    switch ($statusCode) {
                        400 {
                            Write-Warning "Subscription '$subscriptionName' ($subscriptionId) doesn't support Cost Management API (400 Bad Request) - likely unsupported subscription type"
                            Write-Output "Skipping subscription due to unsupported subscription type"
                            continue
                        }
                        401 {
                            Write-Warning "Authentication failed for subscription '$subscriptionName' ($subscriptionId) (401 Unauthorized)"
                            Write-Output "Skipping subscription due to authentication issues"
                            continue
                        }
                        403 {
                            Write-Warning "Access denied for subscription '$subscriptionName' ($subscriptionId) (403 Forbidden) - check Cost Management Reader permissions"
                            Write-Output "Skipping subscription due to insufficient permissions"
                            continue
                        }
                        404 {
                            Write-Warning "Cost Management not available for subscription '$subscriptionName' ($subscriptionId) (404 Not Found)"
                            Write-Output "Skipping subscription due to Cost Management not being available"
                            continue
                        }
                        429 {
                            Write-Warning "Rate limit exceeded during API test for subscription '$subscriptionName' ($subscriptionId) (429 Too Many Requests)"
                            Write-Output "Implementing extended backoff before continuing..."
                            Start-Sleep -Seconds 120  # 2-minute delay for rate limit recovery
                            # Don't skip - continue processing with the enhanced retry logic
                        }
                        default {
                            Write-Warning "Cost Management API test failed for subscription '$subscriptionName' ($subscriptionId) (HTTP $statusCode): $errorDetails"
                            Write-Output "Skipping subscription due to API access issues"
                            continue
                        }
                    }
                }
                
            } catch {
                Write-Warning "Failed to validate subscription '$subscriptionName' ($subscriptionId): $($_.Exception.Message)"
                Write-Output "Skipping subscription due to validation errors"
                continue
            }
            
            # Get cost data for the last 3 days only (instead of 30 days) for daily incremental collection
            $endDate = Get-Date $CollectionDate
            $startDate = $endDate.AddDays(-3)  # Changed from -30 to -3 days for incremental collection
            
            # Enhanced: Use more reliable Cost Management API format with simplified structure
            $subscriptionScope = "/subscriptions/$subscriptionId"
            $apiVersion = "2021-10-01"  # Use stable API version
            
            # Use ActualCost with basic grouping for more predictable response format
            $requestBody = @{
                type = "ActualCost"  # Changed back to ActualCost for more reliable data
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
                            name = "ServiceName"
                        },
                        @{
                            type = "Dimension"
                            name = "ResourceGroupName"
                        }
                    )
                }
            } | ConvertTo-Json -Depth 8
            
            # Get access token for Cost Management API
            $context = Get-AzContext
            $token = [Microsoft.Azure.Commands.Common.Authentication.AzureSession]::Instance.AuthenticationFactory.Authenticate($context.Account, $context.Environment, $context.Tenant.Id, $null, "Never", $null, "https://management.azure.com/").AccessToken
            
            # Make the API call with retry logic and exponential backoff
            $uri = "https://management.azure.com$subscriptionScope/providers/Microsoft.CostManagement/query?api-version=$apiVersion"
            $headers = @{
                "Authorization" = "Bearer $token"
                "Content-Type" = "application/json"
            }
            
            # Add rate limiting delay before main cost data API call
            Write-Output "Pre-cost query delay: $apiCallDelaySeconds seconds"
            Start-Sleep -Seconds $apiCallDelaySeconds
            $totalApiCalls++
            
            # Execute cost query with enhanced retry logic
            $costData = Invoke-CostManagementQuery -Uri $uri -Headers $headers -Body $requestBody -MaxRetries 5 -RateLimitHitCount ([ref]$rateLimitHits)
            
            if ($null -eq $costData -or $costData.Count -eq 0) {
                Write-Warning "No cost data available for subscription '$subscriptionName' ($subscriptionId). Moving to next subscription."
                continue
            }
            
            Write-Output "Retrieved $($costData.Count) cost records for subscription '$subscriptionName' ($subscriptionId)"
            
            # Process cost data with enhanced validation and improved error handling
            # Note: The ActualCost API with ServiceName + ResourceGroupName grouping returns:
            # [Cost, UsageDate, ServiceName, ResourceGroupName, Currency]
            # Field order may vary, so we use intelligent field detection
            
            $validRecords = 0
            $skippedRecords = 0
            $zeroCostRecords = 0
            $totalCost = 0
            $serviceBreakdown = @{}
            
            Write-Output "Starting to process $($costData.Count) cost records..."
            
            foreach ($record in $costData) {
                try {
                    # Enhanced validation with detailed logging for debugging
                    if ($null -eq $record) {
                        Write-Output "Skipping null record"
                        $skippedRecords++
                        continue
                    }
                    
                    if (-not ($record -is [array])) {
                        Write-Output "Skipping non-array record of type: $($record.GetType().Name)"
                        $skippedRecords++
                        continue
                    }
                    
                    if ($record.Count -lt 4) {
                        Write-Output "Skipping record with insufficient fields: $($record.Count) (expected at least 4)"
                        $skippedRecords++
                        continue
                    }
                    
                    # Parse fields with enhanced error handling and flexibility
                    # Field 0: Cost (should be numeric)
                    $costValue = $record[0]
                    if (-not ($costValue -is [double] -or $costValue -is [int] -or $costValue -is [decimal] -or ($costValue -is [string] -and $costValue -match "^-?\d+(\.\d+)?$"))) {
                        Write-Output "Skipping record with non-numeric cost: '$costValue' (Type: $($costValue.GetType().Name))"
                        $skippedRecords++
                        continue
                    }
                    
                    $cost = [double]$costValue
                    
                    # Field 1: Date (can be various formats)
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
                                Write-Output "Skipping record with invalid date format: '$dateString' (length: $($dateString.Length))"
                                $skippedRecords++
                                continue
                            }
                        } elseif ($dateValue -is [string]) {
                            # Handle string date formats
                            if ($dateValue.Length -eq 8 -and $dateValue -match "^\d{8}$") {
                                $year = [int]$dateValue.Substring(0, 4)
                                $month = [int]$dateValue.Substring(4, 2)
                                $day = [int]$dateValue.Substring(6, 2)
                                $date = [datetime]::new($year, $month, $day)
                            } elseif ($dateValue -match "^\d{4}-\d{2}-\d{2}") {
                                $date = [datetime]::Parse($dateValue)
                            } else {
                                $date = [datetime]::Parse($dateValue)
                            }
                        } elseif ($dateValue -is [datetime]) {
                            $date = $dateValue
                        } else {
                            Write-Output "Skipping record with unparseable date: '$dateValue' (Type: $($dateValue.GetType().Name))"
                            $skippedRecords++
                            continue
                        }
                    } catch {
                        Write-Output "Skipping record due to date parsing error: '$dateValue' - $($_.Exception.Message)"
                        $skippedRecords++
                        continue
                    }
                    
                    # Parse remaining fields with improved logic for ActualCost API response
                    # Expected order: [Cost, UsageDate, ServiceName, ResourceGroupName, Currency]
                    $resourceGroup = "Unknown"
                    $serviceName = "Unknown"
                    $currency = "USD"
                    
                    # Use position-based parsing first, then validate with content analysis
                    if ($record.Count -ge 5) {
                        # Standard 5-field response
                        $serviceName = if ($record[2]) { [string]$record[2] } else { "Unknown" }
                        $resourceGroup = if ($record[3]) { [string]$record[3] } else { "Unknown" }
                        $currency = if ($record[4]) { [string]$record[4] } else { "USD" }
                    } elseif ($record.Count -eq 4) {
                        # 4-field response (currency might be missing)
                        $serviceName = if ($record[2]) { [string]$record[2] } else { "Unknown" }
                        $resourceGroup = if ($record[3]) { [string]$record[3] } else { "Unknown" }
                    } else {
                        # Fallback: Try to identify fields by content
                        for ($i = 2; $i -lt $record.Count; $i++) {
                            $fieldValue = $record[$i]
                            if ($null -eq $fieldValue) { continue }
                            
                            $fieldString = [string]$fieldValue
                            
                            # Identify currency field (usually 3-character code)
                            if ($fieldString.Length -eq 3 -and $fieldString -match "^[A-Z]{3}$") {
                                $currency = $fieldString
                            }
                            # Identify resource group (often contains 'rg-' or similar patterns)
                            elseif ($fieldString -like "*rg-*" -or $fieldString -like "*resourcegroup*" -or $fieldString -like "*-rg" -or 
                                    ($fieldString -notmatch "^[A-Z]{3}$" -and $fieldString -notlike "*Virtual*" -and $fieldString -notlike "*Storage*" -and $fieldString -notlike "*Database*")) {
                                $resourceGroup = $fieldString
                            }
                            # Identify service name (usually longer descriptive names)
                            elseif ($fieldString -like "*Virtual*" -or $fieldString -like "*Storage*" -or $fieldString -like "*Network*" -or 
                                    $fieldString -like "*Database*" -or $fieldString -like "*App*" -or $fieldString -like "*Compute*") {
                                $serviceName = $fieldString
                            }
                        }
                    }
                    
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
                    
                    # Skip zero-cost entries for most services to reduce data volume
                    if ($isZeroCost) {
                        # Only keep zero-cost records for critical services to reduce noise
                        $keepZeroCostServices = @(
                            "Virtual Machines",
                            "Storage",
                            "SQL Database", 
                            "App Service"
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
                    
                    # Enhanced AVD resource detection optimized for NIPAzure subscription location
                    $isAVDResource = $false
                    $avdServiceCategory = "Non-AVD"
                    
                    # All AVD resources are located in NIPAzure subscription (77bc541c-d229-4ff3-81c1-928accbff379)
                    # This knowledge allows for more efficient and accurate detection
                    if ($subscriptionId -eq "77bc541c-d229-4ff3-81c1-928accbff379") {
                        # In NIPAzure subscription - use comprehensive AVD detection since this is the AVD home
                        if ($resourceGroup -like "*avd*" -or 
                            $resourceGroup -like "*vdi*" -or
                            $resourceGroup -like "*virtual*desktop*" -or
                            $serviceName -match "Windows Virtual Desktop|Azure Virtual Desktop|Desktop Virtualization" -or
                            $meterCategory -match "Windows Virtual Desktop|Azure Virtual Desktop|Desktop Virtualization" -or
                            $project -like "*AVD*" -or
                            $project -like "*VDI*" -or
                            $environment -like "*VDI*" -or
                            $environment -like "*AVD*" -or
                            ($resourceName -and ($resourceName -like "*avd*" -or $resourceName -like "*vdi*")) -or
                            ($resourceType -and $resourceType -match "Microsoft.DesktopVirtualization") -or
                            # In NIPAzure, detect VMs that are part of AVD deployments more aggressively
                            ($serviceName -match "Virtual Machines" -and ($resourceGroup -like "*avd*" -or $resourceGroup -like "*vdi*" -or $resourceGroup -like "*wvd*")) -or
                            # Detect networking components for AVD in NIPAzure
                            ($serviceName -match "Virtual Network|Network|Bandwidth" -and ($resourceGroup -like "*avd*" -or $resourceGroup -like "*vdi*" -or $resourceGroup -like "*wvd*")) -or
                            # Detect storage for AVD in NIPAzure
                            ($serviceName -match "Storage" -and ($resourceGroup -like "*avd*" -or $resourceGroup -like "*vdi*" -or $resourceGroup -like "*wvd*"))) {
                            $isAVDResource = $true
                            
                            # Enhanced categorization for NIPAzure AVD resources
                            if ($serviceName -match "Virtual Machines" -or $meterCategory -match "Virtual Machines") {
                                $avdServiceCategory = "AVD-Compute"
                            } elseif ($serviceName -match "Virtual Network|Network|Bandwidth" -or $meterCategory -match "Networking") {
                                $avdServiceCategory = "AVD-Network"
                            } elseif ($serviceName -match "Storage" -or $meterCategory -match "Storage") {
                                $avdServiceCategory = "AVD-Storage"
                            } elseif ($serviceName -match "Windows Virtual Desktop|Azure Virtual Desktop|Desktop Virtualization" -or 
                                     $meterCategory -match "Windows Virtual Desktop|Azure Virtual Desktop|Desktop Virtualization") {
                                $avdServiceCategory = "AVD-Core"
                            } elseif ($serviceName -match "Application Gateway|Load Balancer" -or $meterCategory -match "Application Gateway") {
                                $avdServiceCategory = "AVD-LoadBalancing"
                            } elseif ($serviceName -match "Monitor|Insights|Log Analytics" -or $meterCategory -match "Monitor") {
                                $avdServiceCategory = "AVD-Monitoring"
                            } else {
                                $avdServiceCategory = "AVD-Other"
                            }
                        }
                    } else {
                        # Other subscriptions - minimal AVD detection for edge cases only
                        # (AVD resources should primarily be in NIPAzure, but check for cross-subscription components)
                        if ($serviceName -match "Windows Virtual Desktop|Azure Virtual Desktop|Desktop Virtualization" -or
                            $meterCategory -match "Windows Virtual Desktop|Azure Virtual Desktop|Desktop Virtualization" -or
                            $resourceGroup -like "*avd*" -or $resourceGroup -like "*vdi*" -or
                            $project -like "*AVD*" -or $project -like "*VDI*") {
                            $isAVDResource = $true
                            $avdServiceCategory = "AVD-Core"  # Default to core for cross-subscription components
                        }
                    }
                    
                    # Prepare enhanced log entry with available data including AVD categorization
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
                        AVDServiceCategory = $avdServiceCategory  # New field for AVD service-level reporting
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
            
            Write-Output "Processed $validRecords valid cost records for subscription '$subscriptionName' ($subscriptionId) (skipped $skippedRecords invalid records)"
            Write-Output "Cost breakdown: $zeroCostRecords zero-cost records, $($validRecords - $zeroCostRecords) non-zero records, total cost: $($totalCost.ToString('C2'))"
            
            # Show top 5 services by cost
            $topServices = $serviceBreakdown.GetEnumerator() | Sort-Object { $_.Value.Cost } -Descending | Select-Object -First 5
            Write-Output "Top services by cost:"
            foreach ($service in $topServices) {
                Write-Output "  $($service.Key): $($service.Value.Count) records, $($service.Value.Cost.ToString('C2'))"
            }
            
            # Collect Forecast Data
            if ($IncludeForecasting) {
                Write-Output "Collecting forecast data for subscription '$subscriptionName' ($subscriptionId)"
                # Add rate limiting delay before forecast API call
                Write-Output "Pre-forecast delay: $apiCallDelaySeconds seconds"
                Start-Sleep -Seconds $apiCallDelaySeconds
                $totalApiCalls++
                
                $forecastData = Get-CostForecast -SubscriptionId $subscriptionId -Token $token -RateLimitHitCount ([ref]$rateLimitHits)
                
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
                Write-Output "Collecting budget data for subscription '$subscriptionName' ($subscriptionId)"
                # Add rate limiting delay before budget API calls
                Write-Output "Pre-budget delay: $apiCallDelaySeconds seconds"
                Start-Sleep -Seconds $apiCallDelaySeconds
                $totalApiCalls++
                
                try {
                    $budgets = Get-AzConsumptionBudget -ErrorAction SilentlyContinue
                    
                    if ($budgets -and $budgets.Count -gt 0) {
                        foreach ($budget in $budgets) {
                            # Add small delay between budget spend queries
                            Start-Sleep -Seconds 5
                            $totalApiCalls++
                            
                            $currentSpend = Get-CurrentBudgetSpend -Budget $budget -Token $token -RateLimitHitCount ([ref]$rateLimitHits)
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
                        Write-Output "Processed $($budgets.Count) budgets for subscription '$subscriptionName' ($subscriptionId)"
                    } else {
                        Write-Output "No budgets found for subscription '$subscriptionName' ($subscriptionId)"
                    }
                } catch {
                    Write-Warning "Failed to collect budget data for subscription '$subscriptionName' ($subscriptionId): $($_.Exception.Message)"
                    # Continue processing other data types even if budgets fail
                }
            }
            
            # Collect Advisor Recommendations
            if ($IncludeAdvisor) {
                Write-Output "Collecting Azure Advisor cost recommendations for subscription '$subscriptionName' ($subscriptionId)"
                # Add rate limiting delay before advisor API calls
                Write-Output "Pre-advisor delay: $apiCallDelaySeconds seconds"
                Start-Sleep -Seconds $apiCallDelaySeconds
                $totalApiCalls++
                
                try {
                    $recommendations = Get-AdvisorCostRecommendations -SubscriptionId $subscriptionId -Token $token -RateLimitHitCount ([ref]$rateLimitHits)
                    
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
                        Write-Output "Processed $($recommendations.Count) advisor recommendations for subscription '$subscriptionName' ($subscriptionId)"
                    } else {
                        Write-Output "No advisor cost recommendations found for subscription '$subscriptionName' ($subscriptionId) (this may be normal)"
                    }
                } catch {
                    Write-Warning "Failed to collect advisor recommendations for subscription '$subscriptionName' ($subscriptionId): $($_.Exception.Message)"
                    # Continue processing
                }
            }
            
            Write-Output "Completed processing subscription '$subscriptionName' ($subscriptionId)"
            
        } catch {
            Write-Error "Failed to process subscription '$subscriptionName' ($subscriptionId): $($_.Exception.Message)"
        }
    }
    
    Write-Output "Enhanced cost data collection completed successfully for $($subscriptionIds.Count) subscriptions"
    Write-Output "Data collected: Cost Data, Forecasts=$IncludeForecasting, Budgets=$IncludeBudgets, Advisor=$IncludeAdvisor"
    
    # Execution summary with rate limiting metrics
    $scriptEndTime = Get-Date
    $totalExecutionTime = $scriptEndTime - $scriptStartTime
    Write-Output "Execution Summary:"
    Write-Output "  Total execution time: $($totalExecutionTime.TotalMinutes.ToString('F1')) minutes"
    Write-Output "  Total API calls made: $totalApiCalls"
    Write-Output "  Rate limit hits encountered: $rateLimitHits"
    if ($totalApiCalls -gt 0) {
        $rateLimitPercentage = ($rateLimitHits / $totalApiCalls) * 100
        Write-Output "  Rate limit hit percentage: $($rateLimitPercentage.ToString('F1'))%"
    }
    Write-Output "  Average time per subscription: $((($totalExecutionTime.TotalSeconds) / $subscriptionIds.Count).ToString('F1')) seconds"
    
    # Recommendations based on rate limiting performance
    if ($rateLimitHits -gt 0) {
        Write-Output "Rate Limiting Recommendations:"
        Write-Output "  - Consider increasing subscription delay from $subscriptionDelaySeconds to $(($subscriptionDelaySeconds * 1.5).ToString('F0')) seconds"
        Write-Output "  - Consider processing fewer subscriptions per execution"
        Write-Output "  - Monitor Azure Service Health for Cost Management API issues"
        if ($rateLimitPercentage -gt 20) {
            Write-Warning "High rate limit hit rate ($($rateLimitPercentage.ToString('F1'))%) detected - consider significant delay increases"
        }
    } else {
        Write-Output "No rate limiting issues detected - current configuration performing well"
    }
    
} catch {
    Write-Error "Enhanced cost data collection failed: $($_.Exception.Message)"
    throw
}
