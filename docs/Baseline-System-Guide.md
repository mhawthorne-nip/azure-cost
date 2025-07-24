# Azure Cost Management Baseline System Guide

## Overview

The baseline system provides a foundation for cost trend analysis, anomaly detection, and predictive insights in your Azure cost management solution. It calculates multiple types of baselines to help you understand normal spending patterns and identify deviations.

## Baseline Types

### 1. Rolling Averages
- **7-day, 30-day, 60-day rolling averages**
- Provides smooth trend lines for cost patterns
- Separate calculations for AVD and non-AVD resources
- Includes confidence intervals for expected ranges

### 2. Seasonal Patterns  
- **Day-of-week patterns** (e.g., higher costs on weekdays)
- **Week-of-month patterns** (e.g., spikes during month-end)
- **Seasonality strength assessment** (strong/moderate/weak patterns)
- **Peak and low periods identification**

### 3. Service-Specific Baselines
- **Per-service cost baselines** for all Azure services
- **Volatility and predictability metrics**
- **Growth pattern analysis** (rapid growth/stable/declining)
- **Expected cost ranges** with confidence intervals

### 4. Anomaly Detection Thresholds
- **Day-over-day change thresholds** (2 standard deviations)
- **Week-over-week change thresholds**
- **Recent anomaly tracking**
- **Configurable sensitivity levels**

## Setup Instructions

### Initial Setup (One-time)

1. **Deploy the baseline infrastructure:**
   ```powershell
   # Apply Terraform changes to add baseline runbook
   terraform apply
   ```

2. **Ensure you have cost data:**
   ```powershell
   # Check if cost collection is working
   az automation runbook start --resource-group "rg-nip-costing-dev-eus" --automation-account-name "aa-nip-costing-dev-eus" --name "rb-cost-collection"
   ```

3. **Run initial baseline setup:**
   ```powershell
   # Connect to Azure
   Connect-AzAccount

   # Run the baseline calculation script
   .\scripts\BaselineCalculation-Automation.ps1
   ```

### Daily Automated Operation

The baseline system runs automatically every day at 3:00 AM EST (after cost collection at 2:00 AM EST) via the `BaselineCalculation-Automation` runbook.

## Using Baselines in Analysis

### In PowerShell Scripts

```powershell
# Get rolling average baselines
$rollingBaselines = $baselineData | Where-Object { $_.BaselineType_s -eq "RollingAverage" }

# Get current 30-day average for a subscription
$currentAvg = ($rollingBaselines | Where-Object { $_.SubscriptionId_s -eq $subscriptionId } | Select-Object -First 1).Avg30Day_d

# Check if current cost is within normal range
$isNormal = $currentCost -ge $baseline.LowerConfidenceInterval_d -and $currentCost -le $baseline.UpperConfidenceInterval_d

# Get seasonal patterns
$seasonalBaselines = $baselineData | Where-Object { $_.BaselineType_s -eq "Seasonal" }
$peakDay = $seasonalBaselines[0].PeakDayName_s
$seasonalityStrength = $seasonalBaselines[0].PatternStrength_s

# Get service-specific baselines for anomaly detection
$serviceBaselines = $baselineData | Where-Object { $_.BaselineType_s -eq "Service" -and $_.ServiceName_s -eq "Virtual Machines" }
$expectedRange = @{
    Min = $serviceBaselines[0].ExpectedMinCost_d
    Max = $serviceBaselines[0].ExpectedMaxCost_d
    Volatility = $serviceBaselines[0].VolatilityRatio_d
}

# Get anomaly thresholds
$anomalyBaselines = $baselineData | Where-Object { $_.BaselineType_s -eq "Anomaly" }
$dayChangeThreshold = $anomalyBaselines[0].DayUpperThreshold_d
$weekChangeThreshold = $anomalyBaselines[0].WeekUpperThreshold_d
```

### In Log Analytics Queries

```kusto
// Compare current costs to rolling averages
let currentCosts = AzureCostData_CL
| where TimeGenerated >= ago(7d)
| summarize CurrentAvg = avg(todouble(Cost_d)) by SubscriptionId_s;

let baselines = AzureCostBaseline_CL
| where BaselineType_s == "RollingAverage"
| where TimeGenerated >= ago(1d)
| project SubscriptionId_s, Avg30Day_d, UpperConfidenceInterval_d, LowerConfidenceInterval_d;

currentCosts
| join baselines on SubscriptionId_s
| extend 
    VariancePercent = (CurrentAvg - Avg30Day_d) / Avg30Day_d * 100,
    IsAnomalous = CurrentAvg > UpperConfidenceInterval_d or CurrentAvg < LowerConfidenceInterval_d
| where abs(VariancePercent) > 10 or IsAnomalous
| project SubscriptionId_s, CurrentAvg, Avg30Day_d, VariancePercent, IsAnomalous
```

```kusto
// Find services with unusual growth patterns
AzureCostBaseline_CL
| where BaselineType_s == "Service"
| where TimeGenerated >= ago(1d)
| where GrowthTrendPercent_d > 20 or GrowthTrendPercent_d < -20
| project ServiceName_s, GrowthTrendPercent_d, GrowthPattern_s, AvgDailyCost_d, Predictability_s
| order by GrowthTrendPercent_d desc
```

```kusto
// Identify recent cost anomalies
AzureCostBaseline_CL
| where BaselineType_s == "Anomaly"
| where TimeGenerated >= ago(1d)
| where RecentAnomalyCount_d > 0
| project SubscriptionId_s, RecentAnomalyCount_d, RecentAnomalyRate_d, DayUpperThreshold_d, DayLowerThreshold_d
| order by RecentAnomalyRate_d desc
```

... (rest of document unchanged)