# CostDataCollection-MVP.ps1
param(
    [Parameter(Mandatory=$false)]
    [string]$SubscriptionId = "e653ba88-fc91-42f4-b22b-c35e36b00835",
    
    [Parameter(Mandatory=$false)]
    [int]$DaysBack = 7
)

# Ensures you do not inherit an AzContext in your runbook
Disable-AzContextAutosave -Scope Process

function Write-LogAnalytics {
    param(
        [Parameter(Mandatory=$true)][array]$Data,
        [Parameter(Mandatory=$true)][string]$LogType
    )
    
    # Get workspace credentials from automation variables
    $workspaceId = Get-AutomationVariable -Name "LOG_ANALYTICS_WORKSPACE_ID"
    $workspaceKey = Get-AutomationVariable -Name "LOG_ANALYTICS_WORKSPACE_KEY"
    
    # Convert PSCustomObjects to hashtables for proper JSON serialization
    $processedData = $Data | ForEach-Object {
        if ($_ -is [PSCustomObject]) {
            $hashtable = @{}
            $_.PSObject.Properties | ForEach-Object { $hashtable[$_.Name] = $_.Value }
            $hashtable
        } else {
            $_
        }
    }
    
    $bodyAsJson = ConvertTo-Json $processedData -Depth 10
    $body = [System.Text.Encoding]::UTF8.GetBytes($bodyAsJson)
    
    # Build the signature
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
    
    # Send the request
    $uri = "https://" + $workspaceId + ".ods.opinsights.azure.com" + $resource + "?api-version=2016-04-01"
    $headers = @{
        "Authorization" = $authorization
        "Log-Type" = $LogType
        "x-ms-date" = $rfc1123date
        "time-generated-field" = "TimeGenerated"
    }
    
    try {
        $response = Invoke-WebRequest -Uri $uri -Method $method -ContentType $contentType -Headers $headers -Body $body -UseBasicParsing
        return $response.StatusCode
    } catch {
        Write-Error "Failed to send data to Log Analytics: $($_.Exception.Message)"
        throw
    }
}

function Test-AVDResource {
    param(
        [string]$ResourceName,
        [hashtable]$Tags = @{}
    )
    
    # Check if resource name contains AVD-related keywords
    $avdKeywords = @("VD", "AVD", "WVD", "SessionHost", "HostPool")
    
    foreach ($keyword in $avdKeywords) {
        if ($ResourceName -like "*$keyword*") {
            return $true
        }
    }
    
    # Check tags for AVD-related indicators
    if ($Tags.ContainsKey("AVDResource") -and $Tags["AVDResource"] -eq "True") {
        return $true
    }
    
    if ($Tags.ContainsKey("WVDResource") -and $Tags["WVDResource"] -eq "True") {
        return $true
    }
    
    return $false
}

# Main execution
try {
    # Connect to Azure with system-assigned managed identity
    Write-Output "Connecting to Azure with managed identity..."
    $AzureContext = (Connect-AzAccount -Identity).Context
    Write-Output "Successfully connected"
    
    # Set context to the subscription
    Set-AzContext -SubscriptionId $SubscriptionId
    Write-Output "Processing subscription: $SubscriptionId"
    
    $endDate = Get-Date
    $startDate = $endDate.AddDays(-$DaysBack)
    
    # Simplified query for MVP - get aggregated costs
    $uri = "https://management.azure.com/subscriptions/$SubscriptionId/providers/Microsoft.CostManagement/query?api-version=2023-11-01"
    
    $body = @{
        type = 'Usage'
        timeframe = 'Custom'
        timePeriod = @{
            from = $startDate.ToString("yyyy-MM-ddTHH:mm:ssZ")
            to = $endDate.ToString("yyyy-MM-ddTHH:mm:ssZ")
        }
        dataset = @{
            granularity = 'Daily'
            aggregation = @{
                totalCost = @{
                    name = 'Cost'
                    function = 'Sum'
                }
            }
            grouping = @(
                @{
                    type = 'Dimension'
                    name = 'ResourceGroupName'
                },
                @{
                    type = 'Dimension'
                    name = 'ResourceType'
                },
                @{
                    type = 'Dimension'
                    name = 'ResourceLocation'
                },
                @{
                    type = 'Dimension'
                    name = 'ServiceName'
                }
            )
        }
    }
    
    $token = (Get-AzAccessToken).Token
    $headers = @{
        "Authorization" = "Bearer $token"
        "Content-Type" = "application/json"
    }
    
    Write-Output "Querying cost data..."
    $response = Invoke-RestMethod -Uri $uri -Method Post -Headers $headers -Body ($body | ConvertTo-Json -Depth 5)
    
    # Process the response
    $allCostData = @()
    if ($response -and $response.properties -and $response.properties.rows) {
        Write-Output "Response columns: $($response.properties.columns | ConvertTo-Json)"
        foreach ($row in $response.properties.rows) {
            Write-Output "Processing row: $($row | ConvertTo-Json)"
            
            # Create PSCustomObject instead of hashtable for better property access
            # Ensure Cost is always a valid double value
            $costValue = 0.0
            try {
                if ($row[0] -ne $null -and $row[0] -ne "") {
                    $costValue = [double]$row[0]
                }
            } catch {
                Write-Warning "Could not parse cost value '$($row[0])' for row, defaulting to 0"
                $costValue = 0.0
            }
            
            $costRecord = [PSCustomObject]@{
                TimeGenerated = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ss.fffZ")
                SubscriptionId = $SubscriptionId
                Cost = $costValue
                Currency = "USD"
                UsageDate = if ($row.Count -gt 1 -and $row[1]) { $row[1] } else { (Get-Date).ToString("yyyy-MM-dd") }
                ResourceGroup = if ($row.Count -gt 2 -and $row[2]) { $row[2] } else { "Unknown" }
                ResourceType = if ($row.Count -gt 3 -and $row[3]) { $row[3] } else { "Unknown" }
                Location = if ($row.Count -gt 4 -and $row[4]) { $row[4] } else { "Unknown" }
                ServiceName = if ($row.Count -gt 5 -and $row[5]) { $row[5] } else { "Unknown" }
                ResourceName = "Aggregated"
                Tags = @{}
                IsAVDResource = $false  # Will be determined based on service/resource type analysis
            }
            
            # Determine if this is an AVD-related resource based on service name or resource type
            $serviceName = $costRecord.ServiceName
            $resourceType = $costRecord.ResourceType
            $resourceGroup = $costRecord.ResourceGroup
            
            # Check for AVD-related patterns in service names, resource types, or resource groups
            $avdKeywords = @("Virtual Desktop", "WVD", "AVD", "Session Host", "Host Pool", "VD")
            $isAvdRelated = $false
            
            foreach ($keyword in $avdKeywords) {
                if ($serviceName -like "*$keyword*" -or 
                    $resourceType -like "*$keyword*" -or 
                    $resourceGroup -like "*$keyword*") {
                    $isAvdRelated = $true
                    break
                }
            }
            
            $costRecord.IsAVDResource = $isAvdRelated
            
            $allCostData += $costRecord
        }
    } else {
        Write-Output "No cost data returned from API or unexpected response format"
        Write-Output "Response: $($response | ConvertTo-Json -Depth 3)"
    }
    
    Write-Output "Found $($allCostData.Count) cost records"
    
    # Filter out zero-cost records to reduce noise
    $filteredData = $allCostData | Where-Object { $_.Cost -gt 0 }
    Write-Output "After filtering zero-cost records: $($filteredData.Count) records"
    
    # Send to Log Analytics
    if ($filteredData.Count -gt 0) {
        # Debug: Check the structure of the first object
        Write-Output "First filtered object properties:"
        if ($filteredData[0]) {
            $filteredData[0].PSObject.Properties | ForEach-Object {
                Write-Output "  $($_.Name): $($_.Value) (Type: $($_.Value.GetType().Name))"
            }
        }
        
        Write-LogAnalytics -Data $filteredData -LogType "CostManagement"
        Write-Output "Successfully sent cost data to Log Analytics"
        
        # Summary statistics with error handling
        try {
            # Improved error handling with null checks
            $totalCostMeasure = $filteredData | Measure-Object -Property Cost -Sum
            $totalCost = if ($totalCostMeasure -and $null -ne $totalCostMeasure.Sum) { $totalCostMeasure.Sum } else { 0 }
            
            $avdResources = $filteredData | Where-Object { $_.IsAVDResource -eq $true }
            $avdCostMeasure = if ($avdResources) { $avdResources | Measure-Object -Property Cost -Sum } else { $null }
            $avdCost = if ($avdCostMeasure -and $null -ne $avdCostMeasure.Sum) { $avdCostMeasure.Sum } else { 0 }
            
            $nonAvdCost = $totalCost - $avdCost
            
            Write-Output "Cost Summary:"
            Write-Output "  Total Cost: $($totalCost.ToString('C2'))"
            Write-Output "  AVD Resources Cost: $($avdCost.ToString('C2'))"
            Write-Output "  Non-AVD Resources Cost: $($nonAvdCost.ToString('C2'))"
            if ($totalCost -gt 0) {
                Write-Output "  AVD Cost Percentage: $(($avdCost / $totalCost * 100).ToString('F1'))%"
            } else {
                Write-Output "  AVD Cost Percentage: 0.0%"
            }
        } catch {
            Write-Output "Error calculating cost summary: $($_.Exception.Message)"
            # Fallback calculation
            try {
                $costs = $filteredData | ForEach-Object { if ($null -ne $_.Cost) { $_.Cost } else { 0 } }
                $totalCostMeasure = $costs | Measure-Object -Sum
                $totalCost = if ($totalCostMeasure -and $null -ne $totalCostMeasure.Sum) { $totalCostMeasure.Sum } else { 0 }
                Write-Output "  Total Cost (fallback): $($totalCost.ToString('C2'))"
            } catch {
                Write-Output "  Total Cost (fallback failed): Unable to calculate"
            }
        }
    } else {
        Write-Output "No cost data found for the specified period"
    }
    
} catch {
    Write-Error "Cost data collection failed: $($_.Exception.Message)"
    Write-Error "Stack trace: $($_.ScriptStackTrace)"
    throw
}
