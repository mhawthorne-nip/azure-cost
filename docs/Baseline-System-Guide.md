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
   
   # Run the setup script
   .\scripts\Setup-InitialBaselines.ps1
   
   # Or run with what-if to test first
   .\scripts\Setup-InitialBaselines.ps1 -WhatIf
   ```

### Daily Automated Operation

The baseline system runs automatically every day at 1:00 AM (after cost collection at 3:00 AM) via the `rb-baseline-calculation` runbook.

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

## Baseline Data Structure

### AzureCostBaseline_CL Table Schema

| Field | Type | Description |
|-------|------|-------------|
| `BaselineType_s` | string | Type: RollingAverage, Seasonal, Service, Anomaly |
| `SubscriptionId_s` | string | Azure subscription ID |
| `Period_s` | string | Time period (e.g., "30Day", "90Day") |
| `Avg7Day_d` | real | 7-day rolling average cost |
| `Avg30Day_d` | real | 30-day rolling average cost |
| `Avg60Day_d` | real | 60-day rolling average cost |
| `StandardDeviation_d` | real | Cost standard deviation |
| `GrowthTrendPercent_d` | real | Growth trend percentage |
| `TrendDirection_s` | string | Trend: Increasing, Decreasing, Stable |
| `UpperConfidenceInterval_d` | real | Upper 95% confidence interval |
| `LowerConfidenceInterval_d` | real | Lower 95% confidence interval |
| `PeakDayName_s` | string | Day with highest average cost |
| `SeasonalityIndex_d` | real | Seasonal variation strength |
| `ServiceName_s` | string | Azure service name (for Service type) |
| `VolatilityRatio_d` | real | Cost volatility ratio |
| `Predictability_s` | string | High, Medium, Low predictability |
| `DayUpperThreshold_d` | real | Anomaly threshold for day changes |
| `DataQuality_s` | string | High, Medium, Low data quality |

## Monitoring and Maintenance

### Health Checks

1. **Daily baseline creation verification:**
   ```kusto
   AzureCostBaseline_CL
   | where TimeGenerated >= ago(2d)
   | summarize count() by bin(TimeGenerated, 1d), BaselineType_s
   | order by TimeGenerated desc
   ```

2. **Data quality assessment:**
   ```kusto
   AzureCostBaseline_CL
   | where TimeGenerated >= ago(1d)
   | summarize count() by DataQuality_s, BaselineType_s
   ```

3. **Baseline coverage by subscription:**
   ```kusto
   AzureCostBaseline_CL
   | where TimeGenerated >= ago(1d)
   | summarize BaselineTypes = make_set(BaselineType_s) by SubscriptionId_s
   ```

### Troubleshooting

**No baseline data appearing:**
1. Check if cost collection is working first
2. Verify the baseline calculation runbook completed successfully
3. Check Log Analytics ingestion delays (up to 5 minutes)

**Baselines seem inaccurate:**
1. Ensure sufficient historical cost data (minimum 7 days, recommended 30+ days)
2. Check for data quality issues in source cost data
3. Review the `DataQuality_s` field in baseline records

**Missing baseline types:**
1. Verify runbook parameters are correctly set
2. Check for errors in the automation account job history
3. Ensure all required automation variables are configured

### Performance Optimization

- Baseline calculations use optimized queries with appropriate time windows
- Daily calculations only process recent data incrementally
- Historical baselines are preserved for trend analysis
- Service baselines are limited to services with sufficient data points

## Integration with Weekly Analysis

The enhanced weekly analysis engine automatically uses baseline data for:

1. **Trend Analysis:** Comparing current costs to historical baselines
2. **Anomaly Detection:** Identifying costs outside normal ranges
3. **Growth Pattern Recognition:** Detecting accelerating or declining trends
4. **Seasonal Adjustments:** Accounting for expected seasonal variations
5. **Service-Level Insights:** Highlighting services with unusual patterns

## Cost Impact

The baseline system adds minimal cost (~$0.10/month) through:
- Daily runbook execution (~5 minutes)
- Additional Log Analytics data ingestion (~50MB/month)
- No additional Azure resources required

This provides significant value for cost optimization by enabling proactive identification of cost anomalies and trends.
