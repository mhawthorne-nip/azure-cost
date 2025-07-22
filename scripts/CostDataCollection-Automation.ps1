# Cost Data Collection Runbook for Azure Cost Management
# This runbook collects cost data from multiple Azure subscriptions and stores it in Log Analytics

param(
    [string]$CollectionDate = (Get-Date -Format "yyyy-MM-dd")
)

# Main execution
try {
    Write-Output "Starting cost data collection for $CollectionDate"
    
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
    
    # Add rate limiting between subscription processing
    $subscriptionDelaySeconds = 10  # Wait 10 seconds between subscriptions
    
    for ($i = 0; $i -lt $subscriptionIds.Count; $i++) {
        $subscriptionId = $subscriptionIds[$i].Trim()
        Write-Output "Processing subscription $($i + 1) of $($subscriptionIds.Count): $subscriptionId"
        
        # Add delay between subscriptions (except for the first one)
        if ($i -gt 0) {
            Write-Output "Waiting $subscriptionDelaySeconds seconds before processing next subscription..."
            Start-Sleep -Seconds $subscriptionDelaySeconds
        }
        
        try {
            # Set subscription context
            Set-AzContext -SubscriptionId $subscriptionId -Force
            
            # Get cost data for the last 7 days
            $endDate = Get-Date $CollectionDate
            $startDate = $endDate.AddDays(-7)
            
            # Use REST API call to Azure Cost Management with proper error handling and rate limiting
            $subscriptionScope = "/subscriptions/$subscriptionId"
            $apiVersion = "2023-11-01"
            
            # Build the request body for cost query
            $requestBody = @{
                type = "ActualCost"
                timeframe = "Custom"
                timePeriod = @{
                    from = $startDate.ToString("yyyy-MM-dd")
                    to = $endDate.ToString("yyyy-MM-dd")
                }
                dataset = @{
                    granularity = "Daily"
                    aggregation = @{
                        totalCost = @{
                            name = "PreTaxCost"
                            function = "Sum"
                        }
                    }
                    grouping = @(
                        @{
                            type = "Dimension"
                            name = "ResourceGroup"
                        },
                        @{
                            type = "Dimension"
                            name = "ResourceType"
                        },
                        @{
                            type = "Dimension"
                            name = "ResourceLocation"
                        },
                        @{
                            type = "Dimension"
                            name = "MeterCategory"
                        },
                        @{
                            type = "Dimension"
                            name = "ServiceName"
                        }
                    )
                }
            } | ConvertTo-Json -Depth 10
            
            # Get access token for Cost Management API
            $context = Get-AzContext
            $token = [Microsoft.Azure.Commands.Common.Authentication.AzureSession]::Instance.AuthenticationFactory.Authenticate($context.Account, $context.Environment, $context.Tenant.Id, $null, "Never", $null, "https://management.azure.com/").AccessToken
            
            # Make the API call with retry logic and exponential backoff
            $uri = "https://management.azure.com$subscriptionScope/providers/Microsoft.CostManagement/query?api-version=$apiVersion"
            $headers = @{
                "Authorization" = "Bearer $token"
                "Content-Type" = "application/json"
            }
            
            # Retry configuration for rate limiting (429 errors)
            $maxApiRetries = 5
            $apiRetryCount = 0
            $costData = $null
            $baseDelaySeconds = 30  # Start with 30 seconds for rate limiting
            
            while ($apiRetryCount -lt $maxApiRetries -and $null -eq $costData) {
                try {
                    Write-Output "Attempting Cost Management API call for subscription $subscriptionId (attempt $($apiRetryCount + 1) of $maxApiRetries)"
                    $response = Invoke-RestMethod -Uri $uri -Method POST -Headers $headers -Body $requestBody -ErrorAction Stop
                    $costData = $response.properties.rows
                    Write-Output "Retrieved $($costData.Count) cost records for subscription $subscriptionId"
                    break
                } catch {
                    $apiRetryCount++
                    $errorMessage = $_.Exception.Message
                    $statusCode = $null
                    
                    # Extract status code if available
                    if ($_.Exception.Response) {
                        $statusCode = $_.Exception.Response.StatusCode
                    } elseif ($errorMessage -match "(\d{3})") {
                        $statusCode = $matches[1]
                    }
                    
                    Write-Warning "API call failed for subscription $subscriptionId (attempt $apiRetryCount): $errorMessage"
                    
                    # Handle different error types
                    if ($statusCode -eq 429 -or $errorMessage -like "*Too Many Requests*") {
                        # Rate limiting - use exponential backoff with jitter
                        if ($apiRetryCount -lt $maxApiRetries) {
                            $delaySeconds = $baseDelaySeconds * [Math]::Pow(2, $apiRetryCount - 1)
                            $jitter = Get-Random -Minimum 1 -Maximum 10  # Add 1-10 seconds of jitter
                            $totalDelay = $delaySeconds + $jitter
                            Write-Output "Rate limited. Waiting $totalDelay seconds before retry..."
                            Start-Sleep -Seconds $totalDelay
                        }
                    } elseif ($statusCode -eq 401 -or $statusCode -eq 403) {
                        # Authentication/Authorization errors - don't retry
                        Write-Error "Authentication/Authorization error for subscription $subscriptionId. Skipping."
                        break
                    } elseif ($statusCode -eq 404) {
                        # Not found - subscription might not exist or no cost data
                        Write-Warning "No cost data found for subscription $subscriptionId. Skipping."
                        break
                    } else {
                        # Other errors - shorter retry with exponential backoff
                        if ($apiRetryCount -lt $maxApiRetries) {
                            $delaySeconds = 5 * [Math]::Pow(2, $apiRetryCount - 1)
                            Write-Output "Transient error. Waiting $delaySeconds seconds before retry..."
                            Start-Sleep -Seconds $delaySeconds
                        }
                    }
                    
                    if ($apiRetryCount -eq $maxApiRetries) {
                        Write-Warning "Failed to retrieve cost data for subscription $subscriptionId after $maxApiRetries attempts. Skipping."
                    }
                }
            }
            
            # Skip processing if no cost data was retrieved
            if ($null -eq $costData) {
                Write-Warning "No cost data available for subscription $subscriptionId. Moving to next subscription."
                continue
            }
            
            foreach ($record in $costData) {
                # Parse the API response - Cost Management API returns data in column format
                # Columns: [PreTaxCost, Date, ResourceGroup, ResourceType, ResourceLocation, MeterCategory, ServiceName]
                $cost = [double]$record[0]
                $date = [datetime]$record[1]
                $resourceGroup = $record[2]
                $resourceType = $record[3]
                $resourceLocation = $record[4]
                $meterCategory = $record[5]
                $serviceName = $record[6]
                
                # Skip zero-cost entries to reduce noise
                if ($cost -eq 0) { continue }
                
                # Determine if this is an AVD resource
                $isAVDResource = $false
                if ($resourceGroup -like "*avd*" -or 
                    $resourceType -like "*VirtualMachine*" -and $resourceGroup -like "*avd*" -or
                    $meterCategory -eq "Virtual Machines" -and $resourceLocation -like "*avd*" -or
                    $serviceName -like "*virtual*" -and $resourceGroup -like "*avd*") {
                    $isAVDResource = $true
                }
                
                # Prepare log entry
                $logEntry = [PSCustomObject]@{
                    TimeGenerated = $date.ToString("yyyy-MM-ddTHH:mm:ssZ")
                    SubscriptionId = $subscriptionId
                    ResourceGroup = if ($resourceGroup) { $resourceGroup } else { "Unknown" }
                    ResourceName = "N/A"  # Not available in cost management aggregated data
                    ResourceType = if ($resourceType) { $resourceType } else { "Unknown" }
                    ServiceName = if ($serviceName) { $serviceName } else { "Unknown" }
                    MeterCategory = if ($meterCategory) { $meterCategory } else { "Unknown" }
                    Cost = $cost
                    Currency = "USD"  # Cost Management API typically returns USD
                    Location = if ($resourceLocation) { $resourceLocation } else { "Unknown" }
                    IsAVDResource = $isAVDResource
                    CollectionDate = $CollectionDate
                }
                
                # Send to Log Analytics with retry logic and rate limiting
                $logRetryCount = 0
                $maxLogRetries = 3
                $logSuccess = $false
                
                while ($logRetryCount -lt $maxLogRetries -and -not $logSuccess) {
                    try {
                        $json = $logEntry | ConvertTo-Json -Depth 3 -Compress
                        $body = [System.Text.Encoding]::UTF8.GetBytes($json)
                        
                        # Build the signature for Log Analytics API
                        $method = "POST"
                        $contentType = "application/json"
                        $resource = "/api/logs"
                        $rfc1123date = [DateTime]::UtcNow.ToString("r")
                        $contentLength = $body.Length
                        
                        $xHeaders = "x-ms-date:" + $rfc1123date
                        $stringToHash = $method + "`n" + $contentLength + "`n" + $contentType + "`n" + $xHeaders + "`n" + $resource
                        
                        $bytesToHash = [Text.Encoding]::UTF8.GetBytes($stringToHash)
                        $keyBytes = [Convert]::FromBase64String($workspaceKey)
                        
                        $sha256 = New-Object System.Security.Cryptography.HMACSHA256
                        $sha256.Key = $keyBytes
                        $calculatedHash = $sha256.ComputeHash($bytesToHash)
                        $encodedHash = [Convert]::ToBase64String($calculatedHash)
                        $authorization = 'SharedKey {0}:{1}' -f $workspaceId, $encodedHash
                        
                        # Send the data
                        $uri = "https://" + $workspaceId + ".ods.opinsights.azure.com" + $resource + "?api-version=2016-04-01"
                        
                        $headers = @{
                            "Authorization" = $authorization;
                            "Log-Type" = "AzureCostData";
                            "x-ms-date" = $rfc1123date;
                            "time-generated-field" = "TimeGenerated";
                        }
                        
                        $result = Invoke-RestMethod -Uri $uri -Method $method -ContentType $contentType -Headers $headers -Body $body -ErrorAction Stop
                        $logSuccess = $true
                        
                    } catch {
                        $logRetryCount++
                        $logErrorMessage = $_.Exception.Message
                        
                        if ($logErrorMessage -like "*429*" -or $logErrorMessage -like "*Too Many Requests*") {
                            # Rate limiting on Log Analytics
                            if ($logRetryCount -lt $maxLogRetries) {
                                $logDelay = 2 * [Math]::Pow(2, $logRetryCount)  # Exponential backoff: 4, 8, 16 seconds
                                Write-Output "Log Analytics rate limited. Waiting $logDelay seconds..."
                                Start-Sleep -Seconds $logDelay
                            }
                        } else {
                            # Other errors - shorter delay
                            if ($logRetryCount -lt $maxLogRetries) {
                                Start-Sleep -Seconds 1
                            }
                        }
                        
                        if ($logRetryCount -eq $maxLogRetries) {
                            Write-Warning "Failed to send cost record to Log Analytics after $maxLogRetries attempts: $logErrorMessage"
                        }
                    }
                }
                
                # Small delay between log entries to prevent overwhelming Log Analytics
                Start-Sleep -Milliseconds 100
            }
            
            Write-Output "Completed processing subscription $subscriptionId - $($costData.Count) records"
            
        } catch {
            Write-Error "Failed to process subscription $subscriptionId`: $($_.Exception.Message)"
        }
    }  # End of subscription processing for loop
    
    Write-Output "Cost data collection completed successfully for $($subscriptionIds.Count) subscriptions"
    Write-Output "Note: Implemented rate limiting with exponential backoff to handle API throttling (429 errors)"
    
} catch {
    Write-Error "Cost data collection failed: $($_.Exception.Message)"
    throw
}
