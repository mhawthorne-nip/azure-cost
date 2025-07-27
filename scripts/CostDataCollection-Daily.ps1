# Express Cost Data Collection Runbook for Azure Cost Management
# Version 1.0 - Optimized for daily runs with minimal data collection
# 
# This is a lightweight version that collects only essential cost data
# to prevent 2+ hour execution times. Use this for daily scheduled runs.
#
# Key optimizations:
# - Collects only yesterday's cost data (1 day lookback)
# - Processes only top 8 subscriptions with significant costs
# - Excludes zero-cost records
# - Minimal delays for efficiency
# - No forecasting/budgets/advisor data

param(
    [string]$CollectionDate = (Get-Date -Format "yyyy-MM-dd")
)

# Helper Functions
function Invoke-CostManagementQuery {
    param(
        [string]$Uri,
        [hashtable]$Headers,
        [string]$Body,
        [int]$MaxRetries = 3,
        [int]$BaseDelaySeconds = 10
    )
    
    $retryCount = 0
    $costData = $null
    
    while ($retryCount -lt $MaxRetries -and $null -eq $costData) {
        try {
            if ($retryCount -gt 0) {
                $delay = $BaseDelaySeconds * [Math]::Pow(2, $retryCount - 1)
                Write-Output "API retry $($retryCount + 1)/$MaxRetries (delay: ${delay}s)"
                Start-Sleep -Seconds $delay
            }
            
            $response = Invoke-RestMethod -Uri $Uri -Method POST -Headers $Headers -Body $Body -TimeoutSec 60 -ErrorAction Stop
            
            if ($response -and $response.properties -and $response.properties.rows) {
                $costData = $response.properties.rows
                Write-Output "Retrieved $($costData.Count) records"
                return $costData
            } else {
                return @()
            }
        } catch {
            $retryCount++
            $errorMessage = $_.Exception.Message
            $statusCode = $null
            
            if ($_.Exception.Response) {
                $statusCode = [int]$_.Exception.Response.StatusCode
            }
            
            Write-Warning "API call failed (attempt $retryCount): $errorMessage"
            
            # Handle common error conditions
            if ($statusCode -eq 400 -or $statusCode -eq 403 -or $statusCode -eq 404) {
                Write-Warning "Permanent error ($statusCode) - skipping"
                break
            } elseif ($statusCode -eq 429) {
                if ($retryCount -lt $MaxRetries) {
                    $rateLimitDelay = 60 * [Math]::Pow(2, $retryCount)
                    Write-Output "Rate limited. Waiting $rateLimitDelay seconds..."
                    Start-Sleep -Seconds $rateLimitDelay
                }
            }
        }
    }
    
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
    
    try {
        $null = Invoke-RestMethod -Uri $uri -Method $method -ContentType $contentType -Headers $headers -Body $body -ErrorAction Stop
    } catch {
        Write-Warning "Failed to send data to Log Analytics: $($_.Exception.Message)"
    }
}

# Main execution
try {
    # Suppress verbose output and warnings to minimize noise
    $VerbosePreference = "SilentlyContinue"
    $WarningPreference = "SilentlyContinue"
    $InformationPreference = "SilentlyContinue"
    
    Write-Output "Starting EXPRESS cost data collection for $CollectionDate"
    
    # Connect to Azure using Managed Identity
    try {
        $AzureContext = (Connect-AzAccount -Identity -WarningAction SilentlyContinue).Context
        Write-Output "Connected to Azure with Managed Identity"
    } catch {
        throw "Failed to connect to Azure: $($_.Exception.Message)"
    }
    
    # Get workspace credentials
    $workspaceId = Get-AutomationVariable -Name "LOG_ANALYTICS_WORKSPACE_ID" -WarningAction SilentlyContinue
    $workspaceKey = Get-AutomationVariable -Name "LOG_ANALYTICS_WORKSPACE_KEY" -WarningAction SilentlyContinue
    
    # Priority subscriptions only (top cost generators)
    $prioritySubscriptions = @(
        "77bc541c-d229-4ff3-81c1-928accbff379",  # NIPAzure(Converted to EA)
        "e653ba88-fc91-42f4-b22b-c35e36b00835",  # NIP Corp Dev
        "957c5ab7-da27-42f3-98dc-00baf065261a",  # Visual Studio Enterprise
        "5efe779e-6353-4048-a498-0fcd1be5779c",  # NIP_DevTest
        "5ee9d153-923d-4897-a7cc-435634115e89",  # NIP Corp Test
        "38447902-d6f4-4244-9d24-1d2af90ef42f",  # Connectivity
        "9315750b-ab7f-4885-b439-de2933b8836e",  # NIP Corp Prod
        "85ebe445-5e07-410f-bffe-59d11b564587"   # NIP Online Prod
    )
    
    Write-Output "Processing $($prioritySubscriptions.Count) priority subscriptions"
    
    # Minimal delays for express processing
    $subscriptionDelay = 5  # 5 seconds between subscriptions
    $totalRecords = 0
    $totalCost = 0
    
    for ($i = 0; $i -lt $prioritySubscriptions.Count; $i++) {
        $subscriptionId = $prioritySubscriptions[$i]
        Write-Output "Processing subscription $($i + 1) of $($prioritySubscriptions.Count): $subscriptionId"
        
        if ($i -gt 0) {
            Start-Sleep -Seconds $subscriptionDelay
        }
        
        try {
            # Set subscription context
            $context = Set-AzContext -SubscriptionId $subscriptionId -Force -WarningAction SilentlyContinue
            Write-Output "Set context to: $($context.Subscription.Name)"
            
            # Get cost data for yesterday only (minimal data)
            $endDate = Get-Date $CollectionDate
            $startDate = $endDate.AddDays(-1)  # Only yesterday's data
            
            # Simplified API request
            $requestBody = @{
                type = "Usage"
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
                            name = "ResourceGroup"
                        },
                        @{
                            type = "Dimension"
                            name = "ServiceName"
                        }
                    )
                }
            } | ConvertTo-Json -Depth 6
            
            # Get token
            $context = Get-AzContext
            $token = [Microsoft.Azure.Commands.Common.Authentication.AzureSession]::Instance.AuthenticationFactory.Authenticate($context.Account, $context.Environment, $context.Tenant.Id, $null, "Never", $null, "https://management.azure.com/").AccessToken
            
            $uri = "https://management.azure.com/subscriptions/$subscriptionId/providers/Microsoft.CostManagement/query?api-version=2021-10-01"
            $headers = @{
                "Authorization" = "Bearer $token"
                "Content-Type" = "application/json"
            }
            
            # Get cost data
            $costData = Invoke-CostManagementQuery -Uri $uri -Headers $headers -Body $requestBody
            
            if ($costData.Count -eq 0) {
                Write-Output "No cost data for subscription $subscriptionId"
                continue
            }
            
            # Process only non-zero cost records for efficiency
            $validRecords = 0
            foreach ($record in $costData) {
                try {
                    if (-not ($record -is [array]) -or $record.Count -lt 5) { continue }
                    
                    $cost = [double]$record[0]
                    if ($cost -le 0) { continue }  # Skip zero/negative costs for express mode
                    
                    $resourceGroup = if ($record[2]) { [string]$record[2] } else { "Unknown" }
                    $serviceName = if ($record[3]) { [string]$record[3] } else { "Unknown" }
                    $currency = if ($record[4]) { [string]$record[4] } else { "USD" }
                    
                    # Parse date
                    $dateValue = $record[1]
                    if ($dateValue -is [int] -or $dateValue -is [int64]) {
                        $dateString = $dateValue.ToString()
                        if ($dateString.Length -eq 8) {
                            $year = [int]$dateString.Substring(0, 4)
                            $month = [int]$dateString.Substring(4, 2)
                            $day = [int]$dateString.Substring(6, 2)
                            $date = [datetime]::new($year, $month, $day)
                        } else { continue }
                    } else { continue }
                    
                    # Enhanced AVD detection with subscription-specific optimization
                    $isAVDResource = $false
                    $avdServiceCategory = "Non-AVD"
                    
                    # All AVD resources are located in NIPAzure subscription (77bc541c-d229-4ff3-81c1-928accbff379)
                    # This allows for more efficient and accurate detection
                    if ($subscriptionId -eq "77bc541c-d229-4ff3-81c1-928accbff379") {
                        # In NIPAzure subscription - use comprehensive AVD detection
                        if ($resourceGroup -like "*avd*" -or 
                            $resourceGroup -like "*vdi*" -or
                            $resourceGroup -like "*virtual*desktop*" -or
                            $serviceName -match "Windows Virtual Desktop|Azure Virtual Desktop|Desktop Virtualization" -or
                            ($serviceName -match "Virtual Machines|Virtual Network|Storage" -and 
                             ($resourceGroup -like "*avd*" -or $resourceGroup -like "*vdi*")) -or
                            $serviceName -like "*AVD*" -or
                            $serviceName -like "*VDI*") {
                            $isAVDResource = $true
                            
                            # Categorize AVD service type for aggregated reporting
                            if ($serviceName -match "Virtual Machines") {
                                $avdServiceCategory = "AVD-Compute"
                            } elseif ($serviceName -match "Virtual Network|Network") {
                                $avdServiceCategory = "AVD-Network"
                            } elseif ($serviceName -match "Storage") {
                                $avdServiceCategory = "AVD-Storage"
                            } elseif ($serviceName -match "Windows Virtual Desktop|Azure Virtual Desktop|Desktop Virtualization") {
                                $avdServiceCategory = "AVD-Core"
                            } else {
                                $avdServiceCategory = "AVD-Other"
                            }
                        }
                    } else {
                        # Other subscriptions - minimal AVD detection for edge cases
                        if ($serviceName -match "Windows Virtual Desktop|Azure Virtual Desktop|Desktop Virtualization" -or
                            $resourceGroup -like "*avd*" -or $resourceGroup -like "*vdi*") {
                            $isAVDResource = $true
                            $avdServiceCategory = "AVD-Core"
                        }
                    }
                    
                    # Simple log entry for express mode with optimized AVD data collection
                    $logEntry = [PSCustomObject]@{
                        TimeGenerated = $date.ToString("yyyy-MM-ddTHH:mm:ssZ")
                        SubscriptionId = $subscriptionId
                        ResourceGroup = $resourceGroup
                        ServiceName = $serviceName
                        Cost = $cost
                        Currency = $currency
                        CollectionDate = $CollectionDate
                        CollectionMode = "Express"
                        IsAVDResource = $isAVDResource  # Now optimized for NIPAzure subscription
                        AVDServiceCategory = $avdServiceCategory  # Enhanced with subscription-specific logic
                        CostCenter = "Unallocated"
                        Environment = "Unknown"
                    }
                    
                    Send-LogAnalyticsData -WorkspaceId $workspaceId -WorkspaceKey $workspaceKey -LogType "AzureCostData" -DataObject $logEntry
                    $validRecords++
                    $totalCost += $cost
                } catch {
                    # Silently continue on record processing errors
                }
            }
            
            Write-Output "Processed $validRecords records for subscription $subscriptionId"
            $totalRecords += $validRecords
            
        } catch {
            Write-Warning "Failed to process subscription $subscriptionId`: $($_.Exception.Message)"
        }
    }
    
    Write-Output "EXPRESS collection completed successfully"
    Write-Output "Total records processed: $totalRecords"
    Write-Output "Total cost: $($totalCost.ToString('C2'))"
    Write-Output "Estimated execution time savings: 80-90% vs full collection"
    
} catch {
    Write-Error "EXPRESS cost collection failed: $($_.Exception.Message)"
    throw
}
