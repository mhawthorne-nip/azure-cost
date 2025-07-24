# Enhanced Baseline Calculation Runbook for Azure Cost Management
# Version 1.0 - Establishes cost baselines for trend analysis and anomaly detection
# 
# This runbook calculates multiple types of baselines:
# - Historical averages (30, 60, 90 day rolling averages)
# - Seasonal patterns (weekly/monthly patterns)
# - Service-specific baselines
# - Growth trend baselines
# - Variance analysis baselines

param(
    [string]$CalculationDate = (Get-Date -Format "yyyy-MM-dd"),
    [int]$LookbackDays = 90,
    [bool]$IncludeSeasonalAnalysis = $true,
    [bool]$IncludeServiceBaselines = $true,
    [bool]$IncludeGrowthTrends = $true,
    [bool]$IncludeVarianceAnalysis = $true
)

# Ensures you do not inherit an AzContext in your runbook
Disable-AzContextAutosave -Scope Process

# Import required modules
Import-Module Az.Accounts -Force
Import-Module Az.OperationalInsights -Force

function Connect-AzureWithManagedIdentity {
    $maxRetries = 3
    $retryCount = 0
    $connected = $false

    while (-not $connected -and $retryCount -lt $maxRetries) {
        try {
            (Connect-AzAccount -Identity) | Out-Null
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
            Invoke-RestMethod -Uri $uri -Method $method -ContentType $contentType -Headers $headers -Body $body -ErrorAction Stop | Out-Null
            return
        } catch {
            $retryCount++
            if ($retryCount -lt $maxRetries) {
                $delay = 2 * [Math]::Pow(2, $retryCount)
                Start-Sleep -Seconds $delay
            }
        }
    }
    
    throw "Failed to send data to Log Analytics after $maxRetries attempts"
}

function Invoke-LogAnalyticsQuery {
    param(
        [string]$WorkspaceId,
        [string]$Query,
        [string]$QueryName = "Baseline Query"
    )
    
    $maxRetries = 3
    $retryCount = 0
    
    while ($retryCount -lt $maxRetries) {
        try {
            Write-Output "Executing $QueryName (attempt $($retryCount + 1))"
            $queryResults = Invoke-AzOperationalInsightsQuery -WorkspaceId $WorkspaceId -Query $Query -ErrorAction Stop
            
            if ($queryResults.Results) {
                Write-Output "$QueryName completed: $($queryResults.Results.Count) records"
                return $queryResults.Results
            } else {
                Write-Warning "$QueryName returned no results"
                return @()
            }
        } catch {
            $retryCount++
            Write-Warning "$QueryName failed (attempt $retryCount): $($_.Exception.Message)"
            if ($retryCount -lt $maxRetries) {
                Start-Sleep -Seconds (5 * $retryCount)
            }
        }
    }
    
    throw "$QueryName failed after $maxRetries attempts"
}

function Calculate-RollingAverages {
    param(
        [string]$WorkspaceId,
        [string]$CalculationDate,
        [int]$LookbackDays
    )
    
    Write-Output "Calculating rolling averages for the last $LookbackDays days"
    
    # Query to get daily cost totals for rolling average calculation
    $rollingAverageQuery = @"
AzureCostData_CL
| where TimeGenerated >= ago(${LookbackDays}d)
| where isnotempty(Cost_d) and Cost_d > 0
| extend CostDate = format_datetime(TimeGenerated, 'yyyy-MM-dd')
| summarize 
    DailyCost = sum(todouble(Cost_d)),
    AVDCost = sum(iff(IsAVDResource_b == true, todouble(Cost_d), 0)),
    NonAVDCost = sum(iff(IsAVDResource_b == false, todouble(Cost_d), 0)),
    RecordCount = count()
    by CostDate, SubscriptionId_s
| order by CostDate desc
"@

    $costData = Invoke-LogAnalyticsQuery -WorkspaceId $WorkspaceId -Query $rollingAverageQuery -QueryName "Rolling Average Data"
    
    if (-not $costData -or $costData.Count -eq 0) {
        Write-Warning "No cost data available for rolling average calculation"
        return
    }
    
    # Group by subscription and calculate rolling averages
    $subscriptionGroups = $costData | Group-Object -Property SubscriptionId_s
    
    foreach ($subGroup in $subscriptionGroups) {
        $subscriptionId = $subGroup.Name
        $subCostData = $subGroup.Group | Sort-Object { [datetime]$_.CostDate }
        
        Write-Output "Calculating baselines for subscription: $subscriptionId"
        
        # Calculate various rolling averages
        $totalCosts = $subCostData | ForEach-Object { [double]$_.DailyCost }
        $avdCosts = $subCostData | ForEach-Object { [double]$_.AVDCost }
        $nonAvdCosts = $subCostData | ForEach-Object { [double]$_.NonAVDCost }
        
        # 7-day rolling average
        $avg7Day = if ($totalCosts.Count -ge 7) { 
            ($totalCosts | Select-Object -Last 7 | Measure-Object -Average).Average 
        } else { 
            ($totalCosts | Measure-Object -Average).Average 
        }
        
        # 30-day rolling average
        $avg30Day = if ($totalCosts.Count -ge 30) { 
            ($totalCosts | Select-Object -Last 30 | Measure-Object -Average).Average 
        } else { 
            ($totalCosts | Measure-Object -Average).Average 
        }
        
        # 60-day rolling average
        $avg60Day = if ($totalCosts.Count -ge 60) { 
            ($totalCosts | Select-Object -Last 60 | Measure-Object -Average).Average 
        } else { 
            ($totalCosts | Measure-Object -Average).Average 
        }
        
        # Calculate standard deviations for variance analysis
        $totalStdDev = if ($totalCosts.Count -gt 1) {
            $mean = ($totalCosts | Measure-Object -Average).Average
            $variance = ($totalCosts | ForEach-Object { [Math]::Pow($_ - $mean, 2) } | Measure-Object -Average).Average
            [Math]::Sqrt($variance)
        } else { 0 }
        
        # Calculate growth trends
        $growthTrend = if ($totalCosts.Count -ge 14) {
            $recentWeek = ($totalCosts | Select-Object -Last 7 | Measure-Object -Average).Average
            $previousWeek = ($totalCosts | Select-Object -Skip ($totalCosts.Count - 14) | Select-Object -First 7 | Measure-Object -Average).Average
            if ($previousWeek -gt 0) { (($recentWeek - $previousWeek) / $previousWeek) * 100 } else { 0 }
        } else { 0 }
        
        # Create baseline entry
        $baselineEntry = [PSCustomObject]@{
            TimeGenerated = (Get-Date).ToString("yyyy-MM-ddTHH:mm:ssZ")
            CalculationDate = $CalculationDate
            SubscriptionId = $subscriptionId
            BaselineType = "RollingAverage"
            Period = "${LookbackDays}Day"
            
            # Rolling averages
            Avg7Day = [Math]::Round($avg7Day, 2)
            Avg30Day = [Math]::Round($avg30Day, 2)
            Avg60Day = [Math]::Round($avg60Day, 2)
            
            # AVD-specific baselines
            AvgAVD7Day = [Math]::Round(($avdCosts | Select-Object -Last 7 | Measure-Object -Average).Average, 2)
            AvgAVD30Day = [Math]::Round(($avdCosts | Select-Object -Last 30 | Measure-Object -Average).Average, 2)
            AvgNonAVD7Day = [Math]::Round(($nonAvdCosts | Select-Object -Last 7 | Measure-Object -Average).Average, 2)
            AvgNonAVD30Day = [Math]::Round(($nonAvdCosts | Select-Object -Last 30 | Measure-Object -Average).Average, 2)
            
            # Variance metrics
            StandardDeviation = [Math]::Round($totalStdDev, 2)
            CoefficientOfVariation = if ($avg30Day -gt 0) { [Math]::Round(($totalStdDev / $avg30Day) * 100, 2) } else { 0 }
            
            # Trend analysis
            GrowthTrendPercent = [Math]::Round($growthTrend, 2)
            TrendDirection = if ($growthTrend -gt 5) { "Increasing" } elseif ($growthTrend -lt -5) { "Decreasing" } else { "Stable" }
            
            # Data quality metrics
            DataPoints = $totalCosts.Count
            DataQuality = if ($totalCosts.Count -ge 30) { "High" } elseif ($totalCosts.Count -ge 14) { "Medium" } else { "Low" }
            
            # Confidence intervals
            UpperConfidenceInterval = [Math]::Round($avg30Day + (1.96 * $totalStdDev), 2)
            LowerConfidenceInterval = [Math]::Round($avg30Day - (1.96 * $totalStdDev), 2)
        }
        
        # Send to Log Analytics
        Send-LogAnalyticsData -WorkspaceId $workspaceId -WorkspaceKey $workspaceKey -LogType "AzureCostBaseline" -DataObject $baselineEntry
        
        Write-Output "Created rolling average baseline for subscription $subscriptionId - 30-day avg: $($baselineEntry.Avg30Day), trend: $($baselineEntry.TrendDirection)"
    }
}

function Calculate-SeasonalBaselines {
    param(
        [string]$WorkspaceId,
        [string]$CalculationDate
    )
    
    if (-not $IncludeSeasonalAnalysis) {
        Write-Output "Skipping seasonal analysis (disabled)"
        return
    }
    
    Write-Output "Calculating seasonal baselines and patterns"
    
    # Query for seasonal pattern analysis (day of week, week of month)
    $seasonalQuery = @"
AzureCostData_CL
| where TimeGenerated >= ago(90d)
| where isnotempty(Cost_d) and Cost_d > 0
| extend 
    CostDate = format_datetime(TimeGenerated, 'yyyy-MM-dd'),
    DayOfWeek = dayofweek(TimeGenerated),
    WeekOfMonth = weekofyear(TimeGenerated) % 4 + 1,
    MonthOfYear = datetime_part('month', TimeGenerated)
| summarize 
    DailyCost = sum(todouble(Cost_d)),
    RecordCount = count()
    by CostDate, DayOfWeek, WeekOfMonth, MonthOfYear, SubscriptionId_s
| summarize 
    AvgDailyCost = avg(DailyCost),
    MinDailyCost = min(DailyCost),
    MaxDailyCost = max(DailyCost),
    StdDevDailyCost = stdev(DailyCost),
    DataPoints = count()
    by DayOfWeek, WeekOfMonth, MonthOfYear, SubscriptionId_s
| order by SubscriptionId_s, MonthOfYear, WeekOfMonth, DayOfWeek
"@

    $seasonalData = Invoke-LogAnalyticsQuery -WorkspaceId $WorkspaceId -Query $seasonalQuery -QueryName "Seasonal Pattern Data"
    
    if (-not $seasonalData -or $seasonalData.Count -eq 0) {
        Write-Warning "No seasonal data available"
        return
    }
    
    # Group by subscription for seasonal analysis
    $subscriptionGroups = $seasonalData | Group-Object -Property SubscriptionId_s
    
    foreach ($subGroup in $subscriptionGroups) {
        $subscriptionId = $subGroup.Name
        $subSeasonalData = $subGroup.Group
        
        # Calculate day-of-week patterns
        $dayOfWeekPattern = $subSeasonalData | Group-Object -Property DayOfWeek | ForEach-Object {
            $dayData = $_.Group
            @{
                DayOfWeek = $_.Name
                AvgCost = ($dayData | Measure-Object -Property AvgDailyCost -Average).Average
                Volatility = ($dayData | Measure-Object -Property StdDevDailyCost -Average).Average
            }
        }
        
        # Calculate week-of-month patterns
        $weekOfMonthPattern = $subSeasonalData | Group-Object -Property WeekOfMonth | ForEach-Object {
            $weekData = $_.Group
            @{
                WeekOfMonth = $_.Name
                AvgCost = ($weekData | Measure-Object -Property AvgDailyCost -Average).Average
                Volatility = ($weekData | Measure-Object -Property StdDevDailyCost -Average).Average
            }
        }
        
        # Find peak and low periods
        $peakDay = ($dayOfWeekPattern | Sort-Object { $_.AvgCost } -Descending | Select-Object -First 1)
        $lowDay = ($dayOfWeekPattern | Sort-Object { $_.AvgCost } | Select-Object -First 1)
        $peakWeek = ($weekOfMonthPattern | Sort-Object { $_.AvgCost } -Descending | Select-Object -First 1)
        $lowWeek = ($weekOfMonthPattern | Sort-Object { $_.AvgCost } | Select-Object -First 1)
        
        # Calculate seasonal variance
        $overallAvg = ($subSeasonalData | Measure-Object -Property AvgDailyCost -Average).Average
        $seasonalVariance = ($dayOfWeekPattern | ForEach-Object { [Math]::Pow($_.AvgCost - $overallAvg, 2) } | Measure-Object -Average).Average
        
        $seasonalBaselineEntry = [PSCustomObject]@{
            TimeGenerated = (Get-Date).ToString("yyyy-MM-ddTHH:mm:ssZ")
            CalculationDate = $CalculationDate
            SubscriptionId = $subscriptionId
            BaselineType = "Seasonal"
            Period = "90Day"
            
            # Day of week patterns
            PeakDay = [int]$peakDay.DayOfWeek
            PeakDayName = (Get-Culture).DateTimeFormat.DayNames[[int]$peakDay.DayOfWeek]
            PeakDayCost = [Math]::Round($peakDay.AvgCost, 2)
            LowDay = [int]$lowDay.DayOfWeek
            LowDayName = (Get-Culture).DateTimeFormat.DayNames[[int]$lowDay.DayOfWeek]
            LowDayCost = [Math]::Round($lowDay.AvgCost, 2)
            
            # Week of month patterns
            PeakWeek = [int]$peakWeek.WeekOfMonth
            PeakWeekCost = [Math]::Round($peakWeek.AvgCost, 2)
            LowWeek = [int]$lowWeek.WeekOfMonth
            LowWeekCost = [Math]::Round($lowWeek.AvgCost, 2)
            
            # Seasonal metrics
            SeasonalVariance = [Math]::Round($seasonalVariance, 2)
            SeasonalityIndex = [Math]::Round((($peakDay.AvgCost - $lowDay.AvgCost) / $overallAvg) * 100, 2)
            OverallSeasonalAvg = [Math]::Round($overallAvg, 2)
            
            # Pattern strength
            PatternStrength = if ($seasonalVariance -gt ($overallAvg * 0.1)) { "Strong" } elseif ($seasonalVariance -gt ($overallAvg * 0.05)) { "Moderate" } else { "Weak" }
        }
        
        Send-LogAnalyticsData -WorkspaceId $workspaceId -WorkspaceKey $workspaceKey -LogType "AzureCostBaseline" -DataObject $seasonalBaselineEntry
        
        Write-Output "Created seasonal baseline for subscription $subscriptionId - Peak: $($seasonalBaselineEntry.PeakDayName), Low: $($seasonalBaselineEntry.LowDayName)"
    }
}

function Calculate-ServiceBaselines {
    param(
        [string]$WorkspaceId,
        [string]$CalculationDate
    )
    
    if (-not $IncludeServiceBaselines) {
        Write-Output "Skipping service baselines (disabled)"
        return
    }
    
    Write-Output "Calculating service-specific baselines"
    
    # Query for service-level baseline calculation
    $serviceQuery = @"
AzureCostData_CL
| where TimeGenerated >= ago(60d)
| where isnotempty(Cost_d) and Cost_d > 0
| where isnotempty(ServiceName_s)
| extend CostDate = format_datetime(TimeGenerated, 'yyyy-MM-dd')
| summarize 
    DailyCost = sum(todouble(Cost_d)),
    RecordCount = count()
    by CostDate, ServiceName_s, SubscriptionId_s, IsAVDResource_b
| summarize 
    AvgDailyCost = avg(DailyCost),
    MinDailyCost = min(DailyCost),
    MaxDailyCost = max(DailyCost),
    StdDevDailyCost = stdev(DailyCost),
    TotalCost = sum(DailyCost),
    DataPoints = count(),
    // Calculate trend
    RecentAvg = avg(iff(CostDate >= ago(7d), DailyCost, real(null))),
    PreviousAvg = avg(iff(CostDate >= ago(14d) and CostDate < ago(7d), DailyCost, real(null)))
    by ServiceName_s, SubscriptionId_s, IsAVDResource_b
| extend GrowthRate = iff(isnotnull(PreviousAvg) and PreviousAvg > 0, (RecentAvg - PreviousAvg) / PreviousAvg * 100, 0.0)
| order by TotalCost desc
"@

    $serviceData = Invoke-LogAnalyticsQuery -WorkspaceId $WorkspaceId -Query $serviceQuery -QueryName "Service Baseline Data"
    
    if (-not $serviceData -or $serviceData.Count -eq 0) {
        Write-Warning "No service data available for baseline calculation"
        return
    }
    
    foreach ($service in $serviceData) {
        # Skip services with insufficient data
        if ($service.DataPoints -lt 7) {
            Write-Output "Skipping $($service.ServiceName_s) - insufficient data points ($($service.DataPoints))"
            continue
        }
        
        # Calculate volatility metrics
        $volatilityRatio = if ($service.AvgDailyCost -gt 0) { $service.StdDevDailyCost / $service.AvgDailyCost } else { 0 }
        $costRange = $service.MaxDailyCost - $service.MinDailyCost
        $costRangePercent = if ($service.AvgDailyCost -gt 0) { ($costRange / $service.AvgDailyCost) * 100 } else { 0 }
        
        # Determine cost predictability
        $predictability = if ($volatilityRatio -lt 0.1) { "High" } elseif ($volatilityRatio -lt 0.3) { "Medium" } else { "Low" }
        
        # Determine growth pattern
        $growthPattern = if ($service.GrowthRate -gt 10) { "Rapid Growth" } 
                        elseif ($service.GrowthRate -gt 2) { "Steady Growth" }
                        elseif ($service.GrowthRate -gt -2) { "Stable" }
                        elseif ($service.GrowthRate -gt -10) { "Declining" }
                        else { "Rapid Decline" }
        
        $serviceBaselineEntry = [PSCustomObject]@{
            TimeGenerated = (Get-Date).ToString("yyyy-MM-ddTHH:mm:ssZ")
            CalculationDate = $CalculationDate
            SubscriptionId = $service.SubscriptionId_s
            BaselineType = "Service"
            Period = "60Day"
            
            # Service identification
            ServiceName = $service.ServiceName_s
            IsAVDResource = [bool]$service.IsAVDResource_b
            
            # Cost baselines
            AvgDailyCost = [Math]::Round([double]$service.AvgDailyCost, 2)
            MinDailyCost = [Math]::Round([double]$service.MinDailyCost, 2)
            MaxDailyCost = [Math]::Round([double]$service.MaxDailyCost, 2)
            StdDevDailyCost = [Math]::Round([double]$service.StdDevDailyCost, 2)
            TotalCost = [Math]::Round([double]$service.TotalCost, 2)
            
            # Expected ranges (95% confidence interval)
            ExpectedMinCost = [Math]::Round([double]$service.AvgDailyCost - (2 * [double]$service.StdDevDailyCost), 2)
            ExpectedMaxCost = [Math]::Round([double]$service.AvgDailyCost + (2 * [double]$service.StdDevDailyCost), 2)
            
            # Volatility metrics
            VolatilityRatio = [Math]::Round($volatilityRatio, 3)
            CostRangePercent = [Math]::Round($costRangePercent, 2)
            Predictability = $predictability
            
            # Growth metrics
            GrowthRate = [Math]::Round([double]$service.GrowthRate, 2)
            GrowthPattern = $growthPattern
            RecentAvg = [Math]::Round([double]$service.RecentAvg, 2)
            PreviousAvg = [Math]::Round([double]$service.PreviousAvg, 2)
            
            # Data quality
            DataPoints = [int]$service.DataPoints
            DataQuality = if ($service.DataPoints -ge 30) { "High" } elseif ($service.DataPoints -ge 14) { "Medium" } else { "Low" }
        }
        
        Send-LogAnalyticsData -WorkspaceId $workspaceId -WorkspaceKey $workspaceKey -LogType "AzureCostBaseline" -DataObject $serviceBaselineEntry
        
        Write-Output "Created service baseline: $($service.ServiceName_s) - Avg: $($serviceBaselineEntry.AvgDailyCost), Growth: $($serviceBaselineEntry.GrowthPattern)"
    }
}

function Calculate-AnomalyBaselines {
    param(
        [string]$WorkspaceId,
        [string]$CalculationDate
    )
    
    Write-Output "Calculating anomaly detection baselines"
    
    # Query for anomaly baseline calculation
    $anomalyQuery = @"
AzureCostData_CL
| where TimeGenerated >= ago(30d)
| where isnotempty(Cost_d) and Cost_d > 0
| extend CostDate = format_datetime(TimeGenerated, 'yyyy-MM-dd')
| summarize 
    DailyCost = sum(todouble(Cost_d))
    by CostDate, SubscriptionId_s
| order by SubscriptionId_s, CostDate asc
| extend 
    PrevDayCost = prev(DailyCost, 1),
    DayOverDayChange = (DailyCost - prev(DailyCost, 1)) / prev(DailyCost, 1) * 100,
    WeekOverWeekChange = (DailyCost - prev(DailyCost, 7)) / prev(DailyCost, 7) * 100
| where isnotnull(DayOverDayChange)
"@

    $anomalyData = Invoke-LogAnalyticsQuery -WorkspaceId $WorkspaceId -Query $anomalyQuery -QueryName "Anomaly Baseline Data"
    
    if (-not $anomalyData -or $anomalyData.Count -eq 0) {
        Write-Warning "No data available for anomaly baseline calculation"
        return
    }
    
    # Group by subscription for anomaly analysis
    $subscriptionGroups = $anomalyData | Group-Object -Property SubscriptionId_s
    
    foreach ($subGroup in $subscriptionGroups) {
        $subscriptionId = $subGroup.Name
        $subAnomalyData = $subGroup.Group
        
        # Calculate day-over-day change statistics
        $dayChanges = $subAnomalyData | Where-Object { $null -ne $_.DayOverDayChange } | ForEach-Object { [double]$_.DayOverDayChange }
        $weekChanges = $subAnomalyData | Where-Object { $null -ne $_.WeekOverWeekChange } | ForEach-Object { [double]$_.WeekOverWeekChange }
        
        if ($dayChanges.Count -eq 0) {
            Write-Warning "No day-over-day changes available for subscription $subscriptionId"
            continue
        }
        
        # Calculate statistical thresholds for anomaly detection
        $dayChangeAvg = ($dayChanges | Measure-Object -Average).Average
        $dayChangeStdDev = if ($dayChanges.Count -gt 1) {
            $mean = $dayChangeAvg
            $variance = ($dayChanges | ForEach-Object { [Math]::Pow($_ - $mean, 2) } | Measure-Object -Average).Average
            [Math]::Sqrt($variance)
        } else { 0 }
        
        $weekChangeAvg = if ($weekChanges.Count -gt 0) { ($weekChanges | Measure-Object -Average).Average } else { 0 }
        $weekChangeStdDev = if ($weekChanges.Count -gt 1) {
            $mean = $weekChangeAvg
            $variance = ($weekChanges | ForEach-Object { [Math]::Pow($_ - $mean, 2) } | Measure-Object -Average).Average
            [Math]::Sqrt($variance)
        } else { 0 }
        
        # Define anomaly thresholds (2 standard deviations)
        $upperThresholdDay = $dayChangeAvg + (2 * $dayChangeStdDev)
        $lowerThresholdDay = $dayChangeAvg - (2 * $dayChangeStdDev)
        $upperThresholdWeek = $weekChangeAvg + (2 * $weekChangeStdDev)
        $lowerThresholdWeek = $weekChangeAvg - (2 * $weekChangeStdDev)
        
        # Calculate recent anomalies (last 7 days)
        $recentData = $subAnomalyData | Sort-Object { [datetime]$_.CostDate } | Select-Object -Last 7
        $recentAnomalies = $recentData | Where-Object { 
            [double]$_.DayOverDayChange -gt $upperThresholdDay -or [double]$_.DayOverDayChange -lt $lowerThresholdDay 
        }
        
        $anomalyBaselineEntry = [PSCustomObject]@{
            TimeGenerated = (Get-Date).ToString("yyyy-MM-ddTHH:mm:ssZ")
            CalculationDate = $CalculationDate
            SubscriptionId = $subscriptionId
            BaselineType = "Anomaly"
            Period = "30Day"
            
            # Day-over-day thresholds
            DayChangeAvg = [Math]::Round($dayChangeAvg, 2)
            DayChangeStdDev = [Math]::Round($dayChangeStdDev, 2)
            DayUpperThreshold = [Math]::Round($upperThresholdDay, 2)
            DayLowerThreshold = [Math]::Round($lowerThresholdDay, 2)
            
            # Week-over-week thresholds
            WeekChangeAvg = [Math]::Round($weekChangeAvg, 2)
            WeekChangeStdDev = [Math]::Round($weekChangeStdDev, 2)
            WeekUpperThreshold = [Math]::Round($upperThresholdWeek, 2)
            WeekLowerThreshold = [Math]::Round($lowerThresholdWeek, 2)
            
            # Recent anomaly count
            RecentAnomalyCount = $recentAnomalies.Count
            RecentAnomalyRate = [Math]::Round(($recentAnomalies.Count / $recentData.Count) * 100, 2)
            
            # Sensitivity settings
            SensitivityLevel = "Medium" # 2 standard deviations
            MinChangeThreshold = 5 # Minimum 5% change to consider
            
            # Data points for quality assessment
            DataPoints = $dayChanges.Count
            DataQuality = if ($dayChanges.Count -ge 21) { "High" } elseif ($dayChanges.Count -ge 14) { "Medium" } else { "Low" }
        }
        
        Send-LogAnalyticsData -WorkspaceId $workspaceId -WorkspaceKey $workspaceKey -LogType "AzureCostBaseline" -DataObject $anomalyBaselineEntry
        
        Write-Output "Created anomaly baseline for subscription $subscriptionId - Day threshold: ±$([Math]::Round($dayChangeStdDev, 1))%, Recent anomalies: $($recentAnomalies.Count)"
    }
}

# ============================================================================
# MAIN EXECUTION BLOCK
# ============================================================================

try {
    Write-Output "=============================================="
    Write-Output "Azure Cost Management - Baseline Calculation Engine v1.0"
    Write-Output "=============================================="
    Write-Output "Start Time: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') UTC"
    Write-Output "Calculation Date: $CalculationDate"
    Write-Output "Lookback Period: $LookbackDays days"
    Write-Output "Features: Rolling Averages, Seasonal Analysis, Service Baselines, Anomaly Detection"
    Write-Output ""

    # Connect to Azure
    Connect-AzureWithManagedIdentity

    # Get workspace credentials
    try {
        $workspaceId = Get-AutomationVariable -Name "LOG_ANALYTICS_WORKSPACE_ID"
        $workspaceKey = Get-AutomationVariable -Name "LOG_ANALYTICS_WORKSPACE_KEY"
        
        if (-not $workspaceId -or -not $workspaceKey) {
            throw "Log Analytics workspace credentials not found"
        }
        
        Write-Output "Connected to Log Analytics workspace: $workspaceId"
    } catch {
        Write-Error "Failed to get Log Analytics credentials: $($_.Exception.Message)"
        throw
    }

    # Execute baseline calculations
    Write-Output "Starting baseline calculations..."
    
    # 1. Calculate rolling averages (always enabled)
    Calculate-RollingAverages -WorkspaceId $workspaceId -CalculationDate $CalculationDate -LookbackDays $LookbackDays
    
    # 2. Calculate seasonal baselines
    if ($IncludeSeasonalAnalysis) {
        Calculate-SeasonalBaselines -WorkspaceId $workspaceId -CalculationDate $CalculationDate
    }
    
    # 3. Calculate service-specific baselines
    if ($IncludeServiceBaselines) {
        Calculate-ServiceBaselines -WorkspaceId $workspaceId -CalculationDate $CalculationDate
    }
    
    # 4. Calculate anomaly detection baselines
    Calculate-AnomalyBaselines -WorkspaceId $workspaceId -CalculationDate $CalculationDate
    
    $endTime = Get-Date
    $duration = $endTime - $startTime
    
    Write-Output ""
    Write-Output "=============================================="
    Write-Output "Baseline calculation completed successfully!"
    Write-Output "Duration: $($duration.TotalMinutes.ToString('F1')) minutes"
    Write-Output "End Time: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') UTC"
    Write-Output "=============================================="
    
} catch {
    Write-Error "Baseline calculation failed: $($_.Exception.Message)"
    Write-Error "Stack trace: $($_.Exception.StackTrace)"
    throw
}
