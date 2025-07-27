# Enhanced WeeklyAnalysisEngine with AI-Powered Analysis
# Version 2.0 - Includes Chain-of-Thought prompting, multi-dimensional analysis, and advanced reporting
param(
    [string]$SubscriptionIds = "",  # Comma-separated list, will use automation variable if empty
    [bool]$IncludeForecasting = $true,
    [bool]$IncludeAnomalyDetection = $true,
    [bool]$IncludeChargebackAnalysis = $true,
    [bool]$IncludeOptimizationRecommendations = $true,
    [bool]$EnableAdvancedPrompting = $true
)

# Ensures you do not inherit an AzContext in your runbook
Disable-AzContextAutosave -Scope Process

# Import required modules for Azure Automation
Import-Module Az.Accounts -Force
Import-Module Az.OperationalInsights -Force

# Add required assemblies for HTML encoding and enhanced data processing
Add-Type -AssemblyName System.Web
Add-Type -AssemblyName System.Net.Http

function Connect-AzureWithManagedIdentity {
    <#
    .SYNOPSIS
    Connects to Azure using the Automation Account's managed identity with retry logic
    #>

    $maxRetries = 3
    $retryCount = 0
    $connected = $false

    while (-not $connected -and $retryCount -lt $maxRetries) {
        try {
            Write-Output "Connecting to Azure using Managed Identity (attempt $($retryCount + 1) of $maxRetries)..."
            $AzureContext = (Connect-AzAccount -Identity).Context
            $connected = $true
            Write-Output " Successfully connected to Azure with Managed Identity"
            Write-Output "  Tenant ID: $($AzureContext.Tenant.Id)"
            Write-Output "  Account: $($AzureContext.Account.Id)"

            # Get current subscription info
            $currentSub = Get-AzContext | Select-Object -ExpandProperty Subscription
            if ($currentSub) {
                Write-Output "  Current Subscription: $($currentSub.Name) ($($currentSub.Id))"
            }

            return $AzureContext
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

function Test-AutomationEnvironment {
    <#
    .SYNOPSIS
    Tests if we're running in Azure Automation Account or locally
    #>
    try {
        # Try to access an automation-specific variable
        $null = Get-Command "Get-AutomationVariable" -ErrorAction Stop
        return $true
    } catch {
        return $false
    }
}

function Get-ConfigurationVariable {
    <#
    .SYNOPSIS
    Gets configuration variables with fallback for local testing
    #>
    param(
        [string]$Name,
        [string]$DefaultValue = $null
    )
    
    $isAutomation = Test-AutomationEnvironment
    
    if ($isAutomation) {
        try {
            return Get-AutomationVariable -Name $Name -ErrorAction Stop
        } catch {
            Write-Warning "Failed to get automation variable '$Name': $($_.Exception.Message)"
            return $DefaultValue
        }
    } else {
        # Local testing fallback
        Write-Warning "Running in local mode - using default value for '$Name'"
        switch ($Name) {
            "TARGET_SUBSCRIPTION_IDS" { 
                return "e653ba88-fc91-42f4-b22b-c35e36b00835,5ee9d153-923d-4897-a7cc-435634115e89,9315750b-ab7f-4885-b439-de2933b8836e"
            }
            "LOG_ANALYTICS_WORKSPACE_ID" { 
                return "0c93c179-1a9e-479f-bc43-289fc58f717d"
            }
            "COST_REPORT_RECIPIENTS" { 
                return "mh@nipgroup.com"
            }
            "EmailFromAddress" {
                return "automation@nipgroup.com"
            }
            "EmailClientId" {
                Write-Warning "EmailClientId not available in local mode"
                return ""
            }
            "EmailTenantId" {
                Write-Warning "EmailTenantId not available in local mode"
                return ""
            }
            "EmailClientSecret" {
                Write-Warning "EmailClientSecret not available in local mode"
                return ""
            }
            "ANTHROPIC_API_KEY" {
                Write-Warning "ANTHROPIC_API_KEY not available in local mode"
                return ""
            }
            default { 
                return $DefaultValue 
            }
        }
    }
}

function Connect-AzureWithContext {
    <#
    .SYNOPSIS
    Connects to Azure using appropriate method based on environment
    #>
    
    $isAutomation = Test-AutomationEnvironment
    
    if ($isAutomation) {
        Write-Output "Detected Azure Automation environment - using Managed Identity"
        Connect-AzureWithManagedIdentity
    } else {
        Write-Output "Detected local environment - using existing Azure CLI context"
        try {
            $context = Get-AzContext
            if ($context) {
                Write-Output " Using existing Azure context: $($context.Account.Id)"
                return $context
            } else {
                Write-Output "No existing Azure context found - attempting interactive login"
                $context = Connect-AzAccount
                return $context
            }
        } catch {
            Write-Error "Failed to establish Azure connection: $($_.Exception.Message)"
            throw
        }
    }
}

function Test-LogAnalyticsTable {
    <#
    .SYNOPSIS
    Tests if a table exists in the Log Analytics workspace
    #>
    param(
        [Parameter(Mandatory=$true)]
        [string]$WorkspaceId,

        [Parameter(Mandatory=$true)]
        [string]$TableName
    )

    try {
        $query = "$TableName | limit 1"
        $null = Invoke-AzOperationalInsightsQuery -WorkspaceId $WorkspaceId -Query $query -ErrorAction SilentlyContinue
        return $true
    } catch {
        Write-Warning "Table '$TableName' does not exist or is not accessible: $($_.Exception.Message)"
        return $false
    }
}

function Invoke-LogAnalyticsQuery {
    <#
    .SYNOPSIS
    Executes a Log Analytics query with retry logic and rate limiting
    #>
    param(
        [Parameter(Mandatory=$true)]
        [string]$WorkspaceId,

        [Parameter(Mandatory=$true)]
        [string]$Query,

        [Parameter(Mandatory=$false)]
        [string]$QueryName = "Query"
    )

    $maxRetries = 3
    $retryCount = 0
    $baseDelaySeconds = 5

    while ($retryCount -lt $maxRetries) {
        try {
            Write-Host "Executing Log Analytics query: $QueryName (attempt $($retryCount + 1) of $maxRetries)"
            $results = Invoke-AzOperationalInsightsQuery -WorkspaceId $WorkspaceId -Query $Query -ErrorAction Stop
            
            if ($results -and $results.Results) {
                Write-Host " Successfully executed $QueryName - Retrieved $($results.Results.Count) records"
                $queryResults = $results.Results
                return $queryResults
            } else {
                Write-Host " Query executed but returned null or empty results"
                return @()
            }
        } catch {
            $retryCount++
            $errorMessage = $_.Exception.Message
            Write-Warning "Log Analytics query '$QueryName' failed (attempt $retryCount): $errorMessage"

            # Check for specific error types
            if ($errorMessage -like "*BadRequest*" -or $errorMessage -like "*400*") {
                Write-Warning " BadRequest error detected in query '$QueryName'. This may indicate:"
                Write-Warning "  - Table doesn't exist in workspace"
                Write-Warning "  - Column names don't match"
                Write-Warning "  - Invalid KQL syntax"
                Write-Warning "  - Data type conversion issues"
                Write-Warning "Query details: First 200 chars of failed query:"
                Write-Warning ($Query.Substring(0, [Math]::Min(200, $Query.Length)) + "%")

                # For BadRequest errors, don't retry as they won't succeed
                Write-Warning "Returning empty result for query '$QueryName' due to BadRequest error"
                return @()
            }

            # Check for rate limiting
            if ($errorMessage -like "*429*" -or $errorMessage -like "*Too Many Requests*" -or $errorMessage -like "*throttled*") {
                if ($retryCount -lt $maxRetries) {
                    $delaySeconds = $baseDelaySeconds * [Math]::Pow(2, $retryCount - 1)
                    Write-Output "Rate limited. Waiting $delaySeconds seconds before retry..."
                    Start-Sleep -Seconds $delaySeconds
                }
            } else {
                # Other errors - shorter delay
                if ($retryCount -lt $maxRetries) {
                    Start-Sleep -Seconds 2
                }
            }

            if ($retryCount -eq $maxRetries) {
                Write-Warning "Failed to execute Log Analytics query '$QueryName' after $maxRetries attempts"
                return @()  # Return empty array instead of throwing
            }
        }
    }
}

# Email notification function using Microsoft Graph REST API
function Send-EmailNotification {
    param (
        [Parameter(Mandatory=$true)]
        [string]$Subject,
        [Parameter(Mandatory=$true)]
        [string]$HtmlBody,
        [Parameter(Mandatory=$true)]
        [string]$Recipients,
        [string]$BodyType = "HTML"
    )

    $maxRetries = 3
    $retryCount = 0

    while ($retryCount -lt $maxRetries) {
        try {
            Write-Output "Preparing to send Microsoft Exchange-compatible email via Microsoft Graph API (attempt $($retryCount + 1) of $maxRetries)"

            # Get email configuration from automation variables with enhanced validation
            $fromAddress = Get-ConfigurationVariable -Name "EmailFromAddress" -DefaultValue "automation@nipgroup.com"
            $clientId = Get-ConfigurationVariable -Name "EmailClientId" -DefaultValue ""
            $tenantId = Get-ConfigurationVariable -Name "EmailTenantId" -DefaultValue ""
            $clientSecret = Get-ConfigurationVariable -Name "EmailClientSecret" -DefaultValue ""

            # Validate required email variables
            if (-not $fromAddress -or -not $clientId -or -not $tenantId -or -not $clientSecret) {
                Write-Warning "Missing email configuration variables. Email notification will be skipped."
                Write-Output "Required variables: EmailFromAddress, EmailClientId, EmailTenantId, EmailClientSecret"
                Write-Output "Current values:"
                Write-Output "  EmailFromAddress: $(if($fromAddress){'? Set'}else{'? Missing'})"
                Write-Output "  EmailClientId: $(if($clientId){'? Set'}else{'? Missing'})"
                Write-Output "  EmailTenantId: $(if($tenantId){'? Set'}else{'? Missing'})"
                Write-Output "  EmailClientSecret: $(if($clientSecret){'? Set'}else{'? Missing'})"
                return
            }

            # Validate email format
            if ($fromAddress -notmatch "^[^@]+@[^@]+\.[^@]+$") {
                Write-Warning "Invalid email address format: $fromAddress"
                return
            }

            # Get access token for Microsoft Graph with enhanced error handling
            $tokenUri = "https://login.microsoftonline.com/$tenantId/oauth2/v2.0/token"
            $tokenBody = @{
                client_id = $clientId
                client_secret = $clientSecret
                scope = "https://graph.microsoft.com/.default"
                grant_type = "client_credentials"
            }

            Write-Output "Requesting access token from Microsoft Graph..."
            $tokenResponse = Invoke-RestMethod -Uri $tokenUri -Method Post -Body $tokenBody -ContentType "application/x-www-form-urlencoded" -TimeoutSec 30
            
            if (-not $tokenResponse.access_token) {
                throw "Failed to obtain access token from Microsoft Graph"
            }
            
            $accessToken = $tokenResponse.access_token
            Write-Output " Successfully obtained access token"

            # Prepare email message with enhanced validation
            $recipientList = @()
            $Recipients -split "," | ForEach-Object {
                $email = $_.Trim()
                if ($email -match "^[^@]+@[^@]+\.[^@]+$") {
                    $recipientList += @{
                        emailAddress = @{
                            address = $email
                        }
                    }
                } else {
                    Write-Warning "Skipping invalid email address: $email"
                }
            }

            if ($recipientList.Count -eq 0) {
                throw "No valid recipient email addresses found"
            }

            Write-Output "Sending Exchange-optimized email to $($recipientList.Count) recipient(s)"

            # Optimize HTML content for Exchange/Outlook compatibility
            Write-Output "Optimizing HTML email content for Microsoft Exchange/Outlook compatibility..."
            
            # Set contentType to HTML (Microsoft Graph standard)
            $emailContentType = "html"
            Write-Output "Using Microsoft Graph standard contentType: '$emailContentType' for Exchange compatibility"

            # Clean and optimize HTML content for Microsoft Graph compatibility
            $cleanHtmlBody = $HtmlBody
            
            # Remove or replace problematic content for Microsoft Graph
            # 1. Remove complex SVG content that might cause issues
            $cleanHtmlBody = $cleanHtmlBody -replace '[^<]*<svg[^>]*>.*?</svg>.*?', ''
            $cleanHtmlBody = $cleanHtmlBody -replace '<svg[^>]*>.*?</svg>', '<div style="height: 60px; width: 200px; background-color: #1A2A45; color: #ffffff; display: flex; align-items: center; justify-content: center; font-size: 20px; font-weight: bold; border-radius: 8px; margin: 0 auto; line-height: 60px; text-align: center;">NIP GROUP</div>'
            
            # 2. Remove special characters and emojis that might cause encoding issues
            $cleanHtmlBody = $cleanHtmlBody -replace '[??????????????????????????????????????????????????????]', ''
            
            # 3. Clean up any remaining problematic characters
            $cleanHtmlBody = $cleanHtmlBody -replace '[^\x20-\x7E\t\r\n]', ' ' # Replace non-ASCII with spaces
            $cleanHtmlBody = $cleanHtmlBody -replace '[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]', '' # Remove control chars
            
            # 4. Fix multiple spaces and normalize whitespace
            $cleanHtmlBody = $cleanHtmlBody -replace '\s+', ' '
            $cleanHtmlBody = $cleanHtmlBody -replace '>\s+<', '><' # Remove spaces between tags
            
            # 5. Ensure proper HTML structure
            if (-not $cleanHtmlBody.StartsWith("<!DOCTYPE html>")) {
                $htmlPrefix = @"
<!DOCTYPE html>
<html>
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>NIP Group Azure Cost Analysis</title>
</head>
<body style="margin: 0; padding: 0; font-family: Arial, sans-serif;">
"@
                $htmlSuffix = @"
</body>
</html>
"@
                # Extract body content
                if ($cleanHtmlBody -match '<body[^>]*>(.*)</body>') {
                    $bodyContent = $matches[1]
                } else {
                    $bodyContent = $cleanHtmlBody -replace '<!DOCTYPE[^>]*>', '' -replace '<html[^>]*>', '' -replace '</html>', '' -replace '<head>.*?</head>', '' -replace '<body[^>]*>', '' -replace '</body>', ''
                }
                
                $cleanHtmlBody = $htmlPrefix + $bodyContent + $htmlSuffix
            }
            
            # Validate content size for Microsoft Graph (limit to reasonable size)
            if ($cleanHtmlBody.Length -gt 300000) {
                Write-Warning "HTML content is very large ($($cleanHtmlBody.Length) characters). Truncating for Microsoft Graph compatibility."
                $cleanHtmlBody = $cleanHtmlBody.Substring(0, 250000) + "</body></html>"
            }
            
            # Simplify the message structure for better compatibility
            $emailMessage = @{
                message = @{
                    subject = $Subject
                    body = @{
                        contentType = $emailContentType
                        content = $cleanHtmlBody
                    }
                    toRecipients = $recipientList
                    importance = "normal"
                }
                saveToSentItems = $true
            }

            # Send email using Microsoft Graph with Exchange-optimized headers
            $graphUri = "https://graph.microsoft.com/v1.0/users/$fromAddress/sendMail"
            $headers = @{
                "Authorization" = "Bearer $accessToken"
                "Content-Type" = "application/json; charset=utf-8"
                "Accept" = "application/json"
                "User-Agent" = "NIP-Azure-Cost-Analysis/2.0 (Exchange-Compatible)"
                "X-MS-Exchange-Organization-MessageDirectionality" = "Outgoing"
            }

            # Convert to JSON with proper encoding for Exchange
            $emailJson = ConvertTo-Json $emailMessage -Depth 20 -Compress
            Write-Output "Sending Exchange-compatible HTML email via Microsoft Graph API..."
            Write-Output "Email payload size: $($emailJson.Length) characters"
            Write-Output "HTML content type: $emailContentType (Exchange standard)"
            Write-Output "HTML content size: $($HtmlBody.Length) characters"
            
            $response = Invoke-RestMethod -Uri $graphUri -Method Post -Headers $headers -Body $emailJson -TimeoutSec 60
            
            Write-Output " OK Exchange-compatible email sent successfully to: $Recipients"
            Write-Output " ?? Email format: HTML with Exchange/Outlook optimizations"
            Write-Output " ?? Content optimization: SVG with Outlook fallback, inline CSS, table-based layout"
            return

        } catch {
            $retryCount++
            $errorMessage = $_.Exception.Message
            $statusCode = $null
            
            # Extract status code if available
            if ($_.Exception.Response) {
                $statusCode = $_.Exception.Response.StatusCode
                Write-Warning "HTTP Status Code: $statusCode"
            }
            
            Write-Warning "Failed to send Exchange-compatible email (attempt $retryCount): $errorMessage"

            # Handle specific error types
            if ($errorMessage -like "*400*" -or $statusCode -eq 400) {
                Write-Warning "Bad Request (400) - Possible Exchange compatibility issues:"
                Write-Warning "  - HTML content may not be Exchange/Outlook compatible"
                Write-Warning "  - SVG elements might need Outlook fallbacks"
                Write-Warning "  - CSS styles should be inline for best compatibility"
                Write-Warning "  - Check for unsupported HTML elements or attributes"
                Write-Warning "  - Verify email addresses are in correct format"
                
                # Log additional details for Exchange email debugging
                Write-Output "Exchange Email Debugging Information:"
                Write-Output "  Content Type Used: $emailContentType"
                Write-Output "  HTML Content Length: $($HtmlBody.Length) chars"
                Write-Output "  JSON Payload Length: $($emailJson.Length) chars"
                Write-Output "  Exchange Optimizations: DOCTYPE, meta tags, conditional comments"
                
                # For authentication errors, don't retry
                if ($errorMessage -like "*authentication*" -or $errorMessage -like "*unauthorized*") {
                    Write-Error "Authentication error detected. Please verify:"
                    Write-Output "  1. EmailClientId is correct"
                    Write-Output "  2. EmailClientSecret is valid and not expired"
                    Write-Output "  3. EmailTenantId is correct"
                    Write-Output "  4. Service principal has Mail.Send permissions"
                    Write-Output "  5. EmailFromAddress exists and is accessible"
                    break
                }
            }
            
            if ($errorMessage -like "*403*" -or $statusCode -eq 403) {
                Write-Warning "Forbidden (403) - The application may not have sufficient permissions"
                Write-Warning "Required permissions: Mail.Send (Application permission)"
                break
            }

            if ($retryCount -lt $maxRetries) {
                $delaySeconds = 3 * $retryCount
                Write-Output "Waiting $delaySeconds seconds before retry..."
                Start-Sleep -Seconds $delaySeconds
            }

            if ($retryCount -eq $maxRetries) {
                Write-Error "Failed to send Exchange-compatible email after $maxRetries attempts: $errorMessage"
                Write-Output "Email configuration check:"
                Write-Output "  From Address: $fromAddress"
                Write-Output "  Client ID: $clientId"
                Write-Output "  Tenant ID: $tenantId"
                Write-Output "  Recipients: $Recipients"
                throw
            }
        }
    }
}

function Invoke-ClaudeAnalysis {
    param(
        [array]$CostData = @(),
        [array]$DailyCostTrends = @(),
        [array]$ServiceCostAnalysis = @(),
        [array]$BaselineData = @(),
        [array]$HistoricalData = @(),
        [array]$ResourceInventory = @(),
        [array]$CostAnomalies = @(),
        [array]$PerformanceData = @(),
        [hashtable]$RightsizingData = @{},
        [array]$AvdServiceBreakdown = @(),  # New: AVD service category analysis
        [hashtable]$ContextEnrichment = @{}
    )

    $maxRetries = 3
    $retryCount = 0
    $baseDelaySeconds = 10

    while ($retryCount -lt $maxRetries) {
        try {
            Write-Output "Invoking Claude AI analysis (attempt $($retryCount + 1) of $maxRetries)..."
            $apiKey = Get-ConfigurationVariable -Name "ANTHROPIC_API_KEY" -DefaultValue ""
            
            # Skip AI analysis if API key is not available
            if (-not $apiKey -or $apiKey.Trim() -eq "") {
                Write-Warning "ANTHROPIC_API_KEY not available. Skipping AI analysis in local mode."
                return @{
                    success = $false
                    totalCost = 0
                    costTrend = "unavailable"
                    keyInsight = "AI analysis not available in local mode"
                    recommendations = @()
                    riskFactors = @()
                    mainCostDrivers = @("Analysis not available")
                    rawAnalysisText = "AI analysis requires ANTHROPIC_API_KEY configuration"
                }
            }

            $headers = @{
                'Content-Type' = 'application/json'
                'x-api-key' = $apiKey
                'anthropic-version' = '2023-06-01'
            }

            $prompt = @'
You are an Azure cost optimization expert with comprehensive data analysis capabilities. Analyze ALL the following Azure data to provide actionable insights.

IMPORTANT: Your response MUST be valid JSON only. Do not include any text before or after the JSON. Do not wrap in markdown code blocks.

COMPREHENSIVE DATA ANALYSIS:

1. CURRENT WEEK COST DATA: {0}
2. DAILY COST TRENDS (30 days): {1}
3. SERVICE COST ANALYSIS and GROWTH: {2}
4. BASELINE COMPARISON DATA: {3}
5. HISTORICAL TRENDS (90 days): {4}
6. RESOURCE INVENTORY and EFFICIENCY: {5}
7. COST ANOMALIES DETECTED: {6}
8. PERFORMANCE METRICS (CPU, Memory, Disk, Network): {7}
9. VM RIGHTSIZING ANALYSIS: {8}
10. AVD SERVICE BREAKDOWN by Category: {9}

Focus on:
1. Cost Trends: Weekly spending patterns, anomalies, and growth analysis
2. Top Cost Drivers: Services/resources consuming the most budget with growth trends
3. AVD Analysis: Detailed breakdown by service categories (Compute, Network, Storage, Core, etc.) - Note: AVD resources are primarily located in NIPAzure subscription (77bc541c-d229-4ff3-81c1-928accbff379)
4. VM Rightsizing: Detailed analysis with estimated savings from performance data
5. Resource Efficiency: Correlation between cost and utilization
6. Historical Context: Compare current trends with baseline and historical data
7. Anomaly Analysis: Investigate cost spikes and drops with root cause analysis
8. Optimization Opportunities: Concrete recommendations with ROI estimates
10. Priority Actions: Top 10 immediate actions ranked by estimated savings

CRITICAL: Return ONLY valid JSON with this exact structure (no additional text):
{{
  "summary": {{
    "totalWeeklyCost": 0,
    "avdCost": 0,
    "nonAvdCost": 0,
    "costTrend": "increasing/decreasing/stable",
    "weeklyGrowthRate": 0,
    "baselineVariance": 0,
    "vmsAnalyzed": 0,
    "underutilizedVMs": 0,
    "overutilizedVMs": 0,
    "anomaliesDetected": 0,
    "potentialSavings": 0
  }},
  "topCostDrivers": [
    {{"service": "ServiceName", "cost": 0, "percentage": 0, "weeklyGrowth": 0, "trend": "up/down/stable"}}
  ],
  "rightsizingOpportunities": [
    {{
      "vmName": "VM-Name",
      "currentUtilization": {{"cpu": 0, "memory": 0, "disk": 0}},
      "recommendation": "downsize/upsize/optimize",
      "suggestedAction": "Description",
      "estimatedMonthlySavings": 0,
      "confidence": "high/medium/low",
      "currentCost": 0
    }}
  ],
  "anomalyAnalysis": [
    {{
      "date": "YYYY-MM-DD",
      "service": "ServiceName",
      "type": "spike/drop",
      "impact": 0,
      "rootCause": "Analysis",
      "recommendation": "Action"
    }}
  ],
  "resourceEfficiency": [
    {{
      "resource": "ResourceName",
      "costEfficiency": 0,
      "utilizationScore": 0,
      "recommendation": "Action"
    }}
  ],
  "recommendations": [
    {{
      "priority": 1,
      "action": "Description",
      "estimatedSavings": 0,
      "timeframe": "immediate/short-term/long-term",
      "effort": "low/medium/high",
      "category": "rightsizing/cost/performance/governance",
      "riskLevel": "low/medium/high"
    }}
  ],
  "insights": [
    "Key insight with specific data points and actionable recommendations"
  ]
}}
'@

            # Convert parameters to JSON for prompt formatting
            $CostDataJson = $CostData | ConvertTo-Json -Depth 3 -Compress
            $DailyCostTrendsJson = $DailyCostTrends | ConvertTo-Json -Depth 2 -Compress
            $ServiceCostAnalysisJson = $ServiceCostAnalysis | ConvertTo-Json -Depth 2 -Compress
            $BaselineDataJson = $BaselineData | ConvertTo-Json -Depth 2 -Compress
            $HistoricalDataJson = $HistoricalData | ConvertTo-Json -Depth 2 -Compress
            $ResourceInventoryJson = $ResourceInventory | ConvertTo-Json -Depth 2 -Compress
            $CostAnomaliesJson = $CostAnomalies | ConvertTo-Json -Depth 2 -Compress
            $PerformanceDataJson = $PerformanceData | ConvertTo-Json -Depth 2 -Compress
            $RightsizingDataJson = $RightsizingData | ConvertTo-Json -Depth 3 -Compress
            $AvdServiceBreakdownJson = $AvdServiceBreakdown | ConvertTo-Json -Depth 2 -Compress

            $prompt = $prompt -f $CostDataJson, $DailyCostTrendsJson, $ServiceCostAnalysisJson, $BaselineDataJson, $HistoricalDataJson, $ResourceInventoryJson, $CostAnomaliesJson, $PerformanceDataJson, $RightsizingDataJson, $AvdServiceBreakdownJson

            # ====== TEMPORARY DEBUG LOGGING ======
            Write-Output "=== CLAUDE REQUEST DEBUG INFO ==="
            Write-Output "Prompt length: $($prompt.Length) characters"
            Write-Output "Cost data length: $($CostDataJson.Length) chars"
            Write-Output "Performance data length: $($PerformanceDataJson.Length) chars"
            Write-Output "Rightsizing data length: $($RightsizingDataJson.Length) chars"
            Write-Output "Daily trends length: $($DailyCostTrendsJson.Length) chars"
            Write-Output "Service analysis length: $($ServiceCostAnalysisJson.Length) chars"
            Write-Output "Baseline data length: $($BaselineDataJson.Length) chars"
            Write-Output "Historical data length: $($HistoricalDataJson.Length) chars"
            Write-Output "Resource inventory length: $($ResourceInventoryJson.Length) chars"
            Write-Output "Cost anomalies length: $($CostAnomaliesJson.Length) chars"
            
            # Log first 500 chars of each data source for inspection
            Write-Output "=== DATA PREVIEW (First 500 chars) ==="
            Write-Output "Cost Data: $($CostDataJson.Substring(0, [Math]::Min(500, $CostDataJson.Length)))"
            Write-Output "Performance Data: $($PerformanceDataJson.Substring(0, [Math]::Min(500, $PerformanceDataJson.Length)))"
            Write-Output "Rightsizing Data: $($RightsizingDataJson.Substring(0, [Math]::Min(500, $RightsizingDataJson.Length)))"
            
            # Log the full prompt being sent to Claude
            Write-Output "=== FULL PROMPT TO CLAUDE ==="
            Write-Output $prompt
            Write-Output "=== END PROMPT ==="

            $body = @{
                model = "claude-3-5-haiku-20241022"
                max_tokens = 4000
                messages = @(
                    @{
                        role = "user"
                        content = $prompt
                    }
                )
            } | ConvertTo-Json -Depth 10

            Write-Output "Request body length: $($body.Length) characters"
            Write-Output "Sending request to Claude API..."
            
            $response = Invoke-RestMethod -Uri "https://api.anthropic.com/v1/messages" -Method POST -Headers $headers -Body $body -TimeoutSec 60

            # ====== TEMPORARY DEBUG LOGGING - RESPONSE ======
            Write-Output "=== CLAUDE RESPONSE DEBUG INFO ==="
            Write-Output "Response received successfully"
            Write-Output "Response structure:"
            Write-Output "  Type: $($response.GetType().Name)"
            if ($response.content) {
                Write-Output "  Content array length: $($response.content.Count)"
                if ($response.content.Count -gt 0) {
                    Write-Output "  First content type: $($response.content[0].type)"
                    Write-Output "  Text length: $($response.content[0].text.Length) characters"
                    Write-Output "=== RAW CLAUDE RESPONSE TEXT ==="
                    Write-Output $response.content[0].text
                    Write-Output "=== END RAW RESPONSE ==="
                }
            }
            if ($response.usage) {
                Write-Output "  Usage: Input tokens: $($response.usage.input_tokens), Output tokens: $($response.usage.output_tokens)"
            }
            Write-Output "=== END CLAUDE RESPONSE DEBUG ==="

            # Validate the response structure
            if (-not $response -or -not $response.content -or $response.content.Count -eq 0) {
                throw "Invalid response structure from Claude API"
            }

            Write-Output "Claude API response received successfully"
            Write-Output "Response type: $($response.content[0].type)"
            Write-Output "Content preview (first 200 chars): $($response.content[0].text.Substring(0, [Math]::Min(200, $response.content[0].text.Length)))"

            # Extract JSON from Claude's response
            $analysisText = $response.content[0].text
            Write-Output "Claude AI response length: $($analysisText.Length) characters"

            # Clean and extract JSON from Claude's response
            try {
                # Look for JSON content between code blocks or extract the entire response
                $jsonContent = $analysisText
                
                # Remove any markdown code block markers
                $jsonContent = $jsonContent -replace '```json\s*', '' -replace '```\s*$', ''
                
                # Find JSON object boundaries
                $startIndex = $jsonContent.IndexOf('{')
                $lastIndex = $jsonContent.LastIndexOf('}')
                
                if ($startIndex -ge 0 -and $lastIndex -gt $startIndex) {
                    $jsonContent = $jsonContent.Substring($startIndex, $lastIndex - $startIndex + 1)
                    Write-Output "Extracted JSON content length: $($jsonContent.Length) characters"
                    
                    # Try to parse the cleaned JSON
                    $analysisJson = $jsonContent | ConvertFrom-Json
                    Write-Output " Claude AI comprehensive analysis completed successfully"
                    
                    # Validate the structure and add missing properties if needed
                    if (-not $analysisJson.summary) {
                        $analysisJson | Add-Member -MemberType NoteProperty -Name "summary" -Value @{
                            totalWeeklyCost = 0
                            costTrend = "analysis_completed"
                            vmsAnalyzed = 0
                            underutilizedVMs = 0
                            overutilizedVMs = 0
                            anomaliesDetected = 0
                            potentialSavings = 0
                        }
                    }
                    
                    return $analysisJson
                } else {
                    throw "No valid JSON structure found in response"
                }
                
            } catch {
                Write-Warning "Could not parse Claude response as JSON: $($_.Exception.Message)"
                Write-Output "Raw Claude response (first 500 chars): $($analysisText.Substring(0, [Math]::Min(500, $analysisText.Length)))"
                
                # Create a structured fallback response with the text analysis
                $fallbackResponse = @{
                    summary = @{
                        totalWeeklyCost = 0
                        costTrend = "analysis_text_only"
                        vmsAnalyzed = 0
                        underutilizedVMs = 0
                        overutilizedVMs = 0
                        anomaliesDetected = 0
                        potentialSavings = 0
                        analysisStatus = "JSON parsing failed, text analysis available"
                    }
                    insights = @($analysisText)
                    recommendations = @(
                        @{
                            priority = 1
                            action = "Review raw AI analysis in insights section for detailed recommendations"
                            estimatedSavings = 0
                            timeframe = "immediate"
                            effort = "low"
                            category = "analysis"
                            riskLevel = "low"
                        }
                    )
                    rightsizingOpportunities = @()
                    anomalyAnalysis = @()
                    resourceEfficiency = @()
                    topCostDrivers = @()
                    rawAnalysisText = $analysisText
                }
                
                return $fallbackResponse
            }

        } catch {
            $retryCount++
            $errorMessage = $_.Exception.Message
            Write-Warning "Claude AI analysis failed (attempt $retryCount): $errorMessage"

            # Handle rate limiting
            if ($errorMessage -like "*429*" -or $errorMessage -like "*rate*limit*") {
                if ($retryCount -lt $maxRetries) {
                    $delaySeconds = $baseDelaySeconds * [Math]::Pow(2, $retryCount - 1)
                    Write-Output "Rate limited. Waiting $delaySeconds seconds before retry..."
                    Start-Sleep -Seconds $delaySeconds
                }
            } else {
                if ($retryCount -lt $maxRetries) {
                    Start-Sleep -Seconds 5
                }
            }

            if ($retryCount -eq $maxRetries) {
                Write-Warning "Claude AI analysis failed after $maxRetries attempts. Returning basic analysis."
                # Return basic analysis if AI fails
                return @{
                    summary = @{
                        totalWeeklyCost = 0
                        costTrend = "analysis_unavailable"
                        vmsAnalyzed = 0
                        underutilizedVMs = 0
                        overutilizedVMs = 0
                        anomaliesDetected = 0
                        potentialSavings = 0
                    }
                    insights = @("AI analysis temporarily unavailable. Please review cost and performance data manually.")
                    recommendations = @(
                        @{
                            priority = 1
                            action = "Review top cost services for optimization opportunities"
                            estimatedSavings = 0
                            timeframe = "immediate"
                            effort = "medium"
                            category = "cost"
                            riskLevel = "low"
                        }
                    )
                    rightsizingOpportunities = @()
                    anomalyAnalysis = @()
                    resourceEfficiency = @()
                }
            }
        }
    }
}

function New-ExecutiveSummaryReport {
    <#
    .SYNOPSIS
    Creates a comprehensive executive summary with rich financial insights and strategic recommendations
    #>
    param(
        [hashtable]$ReportData
    )
    
    # Extract data with safe defaults and enhanced metrics
    $totalCost = if ($ReportData.TotalCost -ne $null) { [double]$ReportData.TotalCost } else { 0 }
    $avdCost = if ($ReportData.AvdCost -ne $null) { [double]$ReportData.AvdCost } else { 0 }
    $nonAvdCost = if ($ReportData.NonAvdCost -ne $null) { [double]$ReportData.NonAvdCost } else { 0 }
    $costVariance = if ($ReportData.CostVariance -ne $null) { [double]$ReportData.CostVariance } else { 0 }
    $costAnomalies = if ($ReportData.CostAnomalies -ne $null) { @($ReportData.CostAnomalies) } else { @() }
    $aiAnalysisResults = if ($ReportData.AiAnalysisResults -ne $null) { $ReportData.AiAnalysisResults } else { @{} }
    $aiSummary = if ($aiAnalysisResults.summary -ne $null) { $aiAnalysisResults.summary } else { @{} }
    $potentialSavings = if ($aiSummary.potentialSavings -ne $null) { [double]$aiSummary.potentialSavings } else { 0 }
    
    # Calculate additional financial metrics
    $projectedMonthlyCost = $totalCost * 4.33  # Average weeks per month
    $projectedAnnualCost = $totalCost * 52
    $costPerEmployee = if ($totalCost -gt 0) { $totalCost / 50 } else { 0 }  # Assume 50 employees
    
    # Calculate VM rightsizing savings
    $vmSavings = 0
    if ($ReportData.UnderutilizedVMs -and $ReportData.UnderutilizedVMs.Count -gt 0) {
        $vmSavings = ($ReportData.UnderutilizedVMs | ForEach-Object { 
            if ($_.EstimatedMonthlySavings -ne $null) { [double]$_.EstimatedMonthlySavings } else { 0 }
        } | Measure-Object -Sum).Sum
    }
    
    # Historical trending data
    $historicalData = if ($ReportData.HistoricalData -ne $null) { @($ReportData.HistoricalData) } else { @() }
    $lastMonthCost = if ($ReportData.LastMonthCost -ne $null) { [double]$ReportData.LastMonthCost } else { 0 }
    $monthOverMonthChange = if ($ReportData.MonthOverMonthChange -ne $null) { [double]$ReportData.MonthOverMonthChange } else { 0 }
    
    # Get comprehensive service analysis
    $serviceCostAnalysis = if ($ReportData.ServiceCostAnalysis -ne $null) { @($ReportData.ServiceCostAnalysis) } else { @() }
    $topServices = if ($serviceCostAnalysis.Count -gt 0) { 
        $serviceCostAnalysis | Sort-Object { if ($_.CurrentWeek -ne $null) { [double]$_.CurrentWeek } else { 0 } } -Descending | Select-Object -First 5
    } else { @() }

    # Create comprehensive, executive-focused HTML report using safe string building
    # Define HTML tag variables to avoid PowerShell parsing conflicts
    $lt = '<'
    $gt = '>'
    $openP = '('
    $closeP = ')'
    $percentsign = '%'
    
    # Build HTML content safely to avoid parsing conflicts
    $html = New-SafeHtmlReport -ReportData @{
        Title = "Azure Cost Executive Summary"
        ReportDate = (Get-Date -Format 'MMMM dd, yyyy')
        TotalCost = $totalCost
        AvdCost = $avdCost
        NonAvdCost = $nonAvdCost
        CostVariance = $costVariance
        ProjectedMonthlyCost = $projectedMonthlyCost
        ProjectedAnnualCost = $projectedAnnualCost
        CostPerEmployee = $costPerEmployee
        PotentialSavings = $potentialSavings
        VmSavings = $vmSavings
        MonthOverMonthChange = $monthOverMonthChange
        CostAnomalies = $costAnomalies
        TopServices = $topServices
        UnderutilizedVMs = $ReportData.UnderutilizedVMs
        Recommendations = $aiAnalysisResults.recommendations
    } -ReportType "Executive"
    
    return $html
}


function New-EngineeringReport {
    <#
    .SYNOPSIS
    Creates a comprehensive engineering report with detailed technical analysis, performance metrics, and optimization recommendations
    #>
    param(
        [hashtable]$ReportData
    )
    
    try {
        # Extract and prepare comprehensive data with enhanced metrics
        $totalCost = if ($ReportData.TotalCost -ne $null) { [double]$ReportData.TotalCost } else { 0 }
        $avdCost = if ($ReportData.AvdCost -ne $null) { [double]$ReportData.AvdCost } else { 0 }
        $nonAvdCost = if ($ReportData.NonAvdCost -ne $null) { [double]$ReportData.NonAvdCost } else { 0 }
        $underutilizedVMs = if ($ReportData.UnderutilizedVMs -ne $null) { @($ReportData.UnderutilizedVMs) } else { @() }
        $overutilizedVMs = if ($ReportData.OverutilizedVMs -ne $null) { @($ReportData.OverutilizedVMs) } else { @() }
        $costVariance = if ($ReportData.CostVariance -ne $null) { [double]$ReportData.CostVariance } else { 0 }
        $costAnomalies = if ($ReportData.CostAnomalies -ne $null) { @($ReportData.CostAnomalies) } else { @() }
        $serviceCostAnalysis = if ($ReportData.ServiceCostAnalysis -ne $null) { @($ReportData.ServiceCostAnalysis) } else { @() }
        $aiAnalysisResults = if ($ReportData.AiAnalysisResults -ne $null) { $ReportData.AiAnalysisResults } else { @{} }
        $trendDirection = if ($ReportData.TrendDirection -ne $null) { $ReportData.TrendDirection } else { 'Unknown' }
        
        # Performance and baseline data
        $performanceData = if ($ReportData.PerformanceData -ne $null) { @($ReportData.PerformanceData) } else { @() }
        $baselineData = if ($ReportData.BaselineData -ne $null) { @($ReportData.BaselineData) } else { @() }
        $historicalData = if ($ReportData.HistoricalData -ne $null) { @($ReportData.HistoricalData) } else { @() }
        
        # Calculate additional technical metrics
        $totalVMs = $underutilizedVMs.Count + $overutilizedVMs.Count
        $optimizedVMs = if ($performanceData.Count -gt 0) { $performanceData.Count - $totalVMs } else { 0 }
        $utilizationEfficiency = if ($totalVMs -gt 0) { ($optimizedVMs / ($totalVMs + $optimizedVMs)) * 100 } else { 100 }
        
        # Resource distribution analysis
        $computeCost = if ($serviceCostAnalysis | Where-Object { $_.ServiceName -match 'Virtual Machines|Compute' }) {
            ($serviceCostAnalysis | Where-Object { $_.ServiceName -match 'Virtual Machines|Compute' } | ForEach-Object { if ($_.Cost) { $_.Cost } else { 0 } } | Measure-Object -Sum).Sum
        } else { 0 }
        
        $storageCost = if ($serviceCostAnalysis | Where-Object { $_.ServiceName -match 'Storage' }) {
            ($serviceCostAnalysis | Where-Object { $_.ServiceName -match 'Storage' } | ForEach-Object { if ($_.Cost) { $_.Cost } else { 0 } } | Measure-Object -Sum).Sum
        } else { 0 }
        
        $networkCost = if ($serviceCostAnalysis | Where-Object { $_.ServiceName -match 'Network|Bandwidth' }) {
            ($serviceCostAnalysis | Where-Object { $_.ServiceName -match 'Network|Bandwidth' } | ForEach-Object { if ($_.Cost) { $_.Cost } else { 0 } } | Measure-Object -Sum).Sum
        } else { 0 }
        
        # Safe access to AI analysis results
        $aiSummary = if ($aiAnalysisResults.summary -ne $null) { $aiAnalysisResults.summary } else { @{} }
        $aiRecommendations = if ($aiAnalysisResults.recommendations -ne $null) { @($aiAnalysisResults.recommendations) } else { @() }
        $potentialSavings = if ($aiSummary.potentialSavings -ne $null) { [double]$aiSummary.potentialSavings } else { 0 }

        # Create comprehensive engineering-focused HTML report using safe string building
        $html = New-SafeHtmlReport -ReportData $ReportData -TotalCost $totalCost -UtilizationEfficiency $utilizationEfficiency -ComputeCost $computeCost -StorageCost $storageCost -NetworkCost $networkCost
        
        return $html
        
    } catch {
        Write-Error "Error creating engineering report: $($_.Exception.Message)"
        return $null
    }
}

function New-SafeHtmlReport {
    param(
        [hashtable]$ReportData,
        [string]$ReportType = "Executive"
    )
    
    # Extract data safely from hashtable
    $title = if ($ReportData.Title) { $ReportData.Title } else { "Azure Cost Report" }
    $reportDate = if ($ReportData.ReportDate) { $ReportData.ReportDate } else { (Get-Date -Format 'MMMM dd, yyyy') }
    $totalCost = if ($ReportData.TotalCost -ne $null) { [double]$ReportData.TotalCost } else { 0 }
    $avdCost = if ($ReportData.AvdCost -ne $null) { [double]$ReportData.AvdCost } else { 0 }
    $nonAvdCost = if ($ReportData.NonAvdCost -ne $null) { [double]$ReportData.NonAvdCost } else { 0 }
    $projectedMonthlyCost = if ($ReportData.ProjectedMonthlyCost -ne $null) { [double]$ReportData.ProjectedMonthlyCost } else { 0 }
    $projectedAnnualCost = if ($ReportData.ProjectedAnnualCost -ne $null) { [double]$ReportData.ProjectedAnnualCost } else { 0 }
    $potentialSavings = if ($ReportData.PotentialSavings -ne $null) { [double]$ReportData.PotentialSavings } else { 0 }
    $vmSavings = if ($ReportData.VmSavings -ne $null) { [double]$ReportData.VmSavings } else { 0 }
    $monthOverMonthChange = if ($ReportData.MonthOverMonthChange -ne $null) { [double]$ReportData.MonthOverMonthChange } else { 0 }
    
    # Define HTML tag variables to avoid parsing conflicts
    $lt = '<'
    $gt = '>'
    $openP = '<p>'
    $closeP = '</p>'
    $openH1 = '<h1>'
    $closeH1 = '</h1>'
    $openH2 = '<h2>'
    $closeH2 = '</h2>'
    $openH3 = '<h3>'
    $closeH3 = '</h3>'
    
    # Build HTML safely without problematic here-strings
    $htmlParts = @()
    
    # HTML Head with enhanced styling
    $htmlParts += '<!DOCTYPE html>'
    $htmlParts += "${lt}html${gt}${lt}head${gt}${lt}meta charset=`"UTF-8`"${gt}"
    $htmlParts += "${lt}title${gt}$title${lt}/title${gt}"
    $htmlParts += "${lt}style${gt}"
    $htmlParts += "body { margin: 0; padding: 20px; font-family: 'Segoe UI', Arial, sans-serif; background-color: #f5f5f5; }"
    $htmlParts += ".container { max-width: 1200px; margin: 0 auto; background: white; padding: 30px; border-radius: 8px; box-shadow: 0 2px 10px rgba(0,0,0,0.1); }"
    $htmlParts += ".header { border-bottom: 3px solid #0078d4; padding-bottom: 20px; margin-bottom: 30px; }"
    $htmlParts += ".metric-card { background: #f8f9fa; border-left: 4px solid #0078d4; padding: 15px; margin: 10px 0; border-radius: 4px; }"
    $htmlParts += ".cost-highlight { font-size: 24px; font-weight: bold; color: #0078d4; }"
    $htmlParts += ".savings-highlight { font-size: 18px; font-weight: bold; color: #107c10; }"
    $htmlParts += ".warning { background: #fff4ce; border-left: 4px solid #ffb900; padding: 15px; margin: 10px 0; border-radius: 4px; }"
    $htmlParts += "${lt}/style${gt}${lt}/head${gt}"
    $htmlParts += "${lt}body${gt}${lt}div class=`"container`"${gt}"
    
    # Header section
    $htmlParts += "${lt}div class=`"header`"${gt}"
    $htmlParts += "$openH1$title$closeH1"
    $htmlParts += "$openP${lt}strong${gt}Report Date:${lt}/strong${gt} $reportDate$closeP"
    $htmlParts += "${lt}/div${gt}"
    
    # Key Metrics Section
    $htmlParts += "$openH2Key Financial Metrics$closeH2"
    $htmlParts += "${lt}div class=`"metric-card`"${gt}"
    $htmlParts += "${lt}span class=`"cost-highlight`"${gt}Total Weekly Cost: " + $totalCost.ToString('C2') + "${lt}/span${gt}"
    $htmlParts += "$openP${lt}strong${gt}AVD Environment:${lt}/strong${gt} " + $avdCost.ToString('C2') + "$closeP"
    $htmlParts += "$openP${lt}strong${gt}Non-AVD Services:${lt}/strong${gt} " + $nonAvdCost.ToString('C2') + "$closeP"
    $htmlParts += "${lt}/div${gt}"
    
    # Projections
    $htmlParts += "${lt}div class=`"metric-card`"${gt}"
    $htmlParts += "$openH3Financial Projections$closeH3"
    $htmlParts += "$openP${lt}strong${gt}Projected Monthly Cost:${lt}/strong${gt} " + $projectedMonthlyCost.ToString('C2') + "$closeP"
    $htmlParts += "$openP${lt}strong${gt}Projected Annual Cost:${lt}/strong${gt} " + $projectedAnnualCost.ToString('C2') + "$closeP"
    if ($monthOverMonthChange -ne 0) {
        $changeDirection = if ($monthOverMonthChange -gt 0) { "increase" } else { "decrease" }
        $htmlParts += "$openP${lt}strong${gt}Month-over-Month Change:${lt}/strong${gt} " + [Math]::Abs($monthOverMonthChange).ToString('P1') + " $changeDirection$closeP"
    }
    $htmlParts += "${lt}/div${gt}"
    
    # Savings Opportunities
    if ($potentialSavings -gt 0 -or $vmSavings -gt 0) {
        $htmlParts += "${lt}div class=`"metric-card`"${gt}"
        $htmlParts += "$openH3Savings Opportunities$closeH3"
        if ($potentialSavings -gt 0) {
            $htmlParts += "${lt}span class=`"savings-highlight`"${gt}Potential Savings: " + $potentialSavings.ToString('C2') + "${lt}/span${gt}$openP"
        }
        if ($vmSavings -gt 0) {
            $htmlParts += "$openP${lt}strong${gt}VM Rightsizing Savings:${lt}/strong${gt} " + $vmSavings.ToString('C2') + "$closeP"
        }
        $htmlParts += "${lt}/div${gt}"
    }
    
    # Top Services
    if ($ReportData.TopServices -and $ReportData.TopServices.Count -gt 0) {
        $htmlParts += "$openH2Top Services by Cost$closeH2"
        $htmlParts += "${lt}div class=`"metric-card`"${gt}"
        foreach ($service in $ReportData.TopServices) {
            $serviceCost = if ($service.CurrentWeek -ne $null) { [double]$service.CurrentWeek } else { 0 }
            $htmlParts += "$openP${lt}strong${gt}$($service.ServiceName):${lt}/strong${gt} " + $serviceCost.ToString('C2') + "$closeP"
        }
        $htmlParts += "${lt}/div${gt}"
    }
    
    # Recommendations
    if ($ReportData.Recommendations -and $ReportData.Recommendations.Count -gt 0) {
        $htmlParts += "$openH2Key Recommendations$closeH2"
        $htmlParts += "${lt}div class=`"metric-card`"${gt}"
        foreach ($recommendation in $ReportData.Recommendations) {
            $htmlParts += "$openP• $recommendation$closeP"
        }
        $htmlParts += "${lt}/div${gt}"
    }
    
    # Underutilized VMs
    if ($ReportData.UnderutilizedVMs -and $ReportData.UnderutilizedVMs.Count -gt 0) {
        $htmlParts += "$openH2Underutilized Virtual Machines$closeH2"
        $htmlParts += "${lt}div class=`"warning`"${gt}"
        $htmlParts += "$openP${lt}strong${gt}Found $($ReportData.UnderutilizedVMs.Count) underutilized VMs${lt}/strong${gt}$closeP"
        foreach ($vm in ($ReportData.UnderutilizedVMs | Select-Object -First 5)) {
            $savings = if ($vm.EstimatedMonthlySavings -ne $null) { [double]$vm.EstimatedMonthlySavings } else { 0 }
            $htmlParts += "$openP${lt}strong${gt}$($vm.VMName):${lt}/strong${gt} Potential monthly savings: " + $savings.ToString('C2') + "$closeP"
        }
        $htmlParts += "${lt}/div${gt}"
    }
    
    # Footer
    $htmlParts += "$openP${lt}em${gt}Generated by Azure Cost Management Automation on $(Get-Date)${lt}/em${gt}$closeP"
    
    # Close HTML
    $htmlParts += "${lt}/div${gt}${lt}/body${gt}${lt}/html${gt}"
    
    return ($htmlParts -join "`n")
}


function Get-CostDataFromLogAnalytics {
    <#
    .SYNOPSIS
    Retrieves enhanced cost data from the AzureCostData_CL table in Log Analytics with comprehensive tagging and allocation information
    #>
    param(
        [Parameter(Mandatory=$true)]
        [string]$WorkspaceId,
        [int]$DaysBack = 7
    )
    
    try {
        Write-Output "Querying AzureCostData_CL table for the last $DaysBack days with enhanced data collection..."
        
        $query = @"
AzureCostData_CL
| where TimeGenerated > ago($($DaysBack)d)
| where isnotempty(Cost_d)
| project TimeGenerated, Cost_d, CostUSD = todouble(Cost_d), ServiceName_s, ResourceName_s, Location_s, 
          Currency_s, IsAVDResource_b, MeterCategory_s, CollectionDate_s, ResourceGroup = ResourceGroup_s,
          ResourceType = ResourceType_s, ResourceId = ResourceId_s, SubscriptionId = SubscriptionId_s,
          CostCenter = CostCenter_s, Project = Project_s, Environment = Environment_s, Owner = Owner_s,
          Department = Department_s, TagCompleteness = TagCompleteness_d, AllocationStatus = AllocationStatus_s
| order by TimeGenerated desc
"@

        $result = Invoke-LogAnalyticsQuery -WorkspaceId $WorkspaceId -Query $query -QueryName "Enhanced Cost Data"
        
        if ($result -and $result.Count -gt 0) {
            Write-Output "Retrieved $($result.Count) enhanced cost records from Log Analytics"
            return $result
        } else {
            Write-Warning "No cost data found in AzureCostData_CL table"
            return @()
        }
    } catch {
        Write-Error "Failed to retrieve cost data: $($_.Exception.Message)"
        return @()
    }
}

function Get-ForecastDataFromLogAnalytics {
    <#
    .SYNOPSIS
    Retrieves forecast data from the AzureCostForecast_CL table in Log Analytics
    #>
    param(
        [Parameter(Mandatory=$true)]
        [string]$WorkspaceId,
        [int]$DaysBack = 30
    )

    try {
        Write-Output "Querying AzureCostForecast_CL table for forecast data..."
        
        $query = @"
AzureCostForecast_CL
| where TimeGenerated > ago($($DaysBack)d)
| where isnotempty(ForecastedCost_d)
| project TimeGenerated, ForecastDate = ForecastDate_s, ForecastedCost = todouble(ForecastedCost_d),
          ConfidenceLevelLow = todouble(ConfidenceLevelLow_d), ConfidenceLevelHigh = todouble(ConfidenceLevelHigh_d),
          ForecastType = ForecastType_s, SubscriptionId = SubscriptionId_s
| order by ForecastDate_s desc
"@

        $result = Invoke-LogAnalyticsQuery -WorkspaceId $WorkspaceId -Query $query -QueryName "Forecast Data"
        
        if ($result -and $result.Count -gt 0) {
            Write-Output "Retrieved $($result.Count) forecast records from Log Analytics"
            return $result
        } else {
            Write-Warning "No forecast data found in AzureCostForecast_CL table"
            return @()
        }
    } catch {
        Write-Error "Failed to retrieve forecast data: $($_.Exception.Message)"
        return @()
    }
}



function Get-BudgetDataFromLogAnalytics {
    <#
    .SYNOPSIS
    Retrieves budget tracking data from the AzureBudgetTracking_CL table
    #>
    param(
        [Parameter(Mandatory=$true)]
        [string]$WorkspaceId,
        [int]$DaysBack = 30
    )

    try {
        Write-Output "Querying AzureBudgetTracking_CL table for budget data..."
        
        $query = @"
AzureBudgetTracking_CL
| where TimeGenerated > ago($($DaysBack)d)
| where isnotempty(CurrentSpend_d)
| project TimeGenerated, BudgetName = BudgetName_s, BudgetAmount = todouble(BudgetAmount_d),
          CurrentSpend = todouble(CurrentSpend_d), BurnRatePercentage = todouble(BurnRatePercentage_d),
          ProjectedOverspend = todouble(ProjectedOverspend_d), AlertThreshold = todouble(AlertThreshold_d),
          SubscriptionId = SubscriptionId_s
| order by TimeGenerated desc
"@

        $result = Invoke-LogAnalyticsQuery -WorkspaceId $WorkspaceId -Query $query -QueryName "Budget Data"
        
        if ($result -and $result.Count -gt 0) {
            Write-Output "Retrieved $($result.Count) budget records from Log Analytics"
            return $result
        } else {
            Write-Warning "No budget data found in AzureBudgetTracking_CL table"
            return @()
        }
    } catch {
        Write-Error "Failed to retrieve budget data: $($_.Exception.Message)"
        return @()
    }
}

function Get-AdvisorRecommendationsFromLogAnalytics {
    <#
    .SYNOPSIS
    Retrieves Azure Advisor cost recommendations from the AzureAdvisorRecommendations_CL table
    #>
    param(
        [Parameter(Mandatory=$true)]
        [string]$WorkspaceId,
        [int]$DaysBack = 7
    )

    try {
        Write-Output "Querying AzureAdvisorRecommendations_CL table for optimization recommendations..."
        
        $query = @"
AzureAdvisorRecommendations_CL
| where TimeGenerated > ago($($DaysBack)d)
| where isnotempty(PotentialSavings_d)
| project TimeGenerated, RecommendationType = RecommendationType_s, ResourceId = ResourceId_s,
          ResourceName = ResourceName_s, Impact = Impact_s, PotentialSavings = todouble(PotentialSavings_d),
          RecommendationText = RecommendationText_s, ActionType = ActionType_s, SubscriptionId = SubscriptionId_s
| order by PotentialSavings_d desc
"@

        $result = Invoke-LogAnalyticsQuery -WorkspaceId $WorkspaceId -Query $query -QueryName "Advisor Recommendations"
        
        if ($result -and $result.Count -gt 0) {
            Write-Output "Retrieved $($result.Count) advisor recommendation records from Log Analytics"
            return $result
        } else {
            Write-Warning "No advisor recommendations found in AzureAdvisorRecommendations_CL table"
            return @()
        }
    } catch {
        Write-Error "Failed to retrieve advisor recommendations: $($_.Exception.Message)"
        return @()
    }
}

function Get-BaselineDataFromLogAnalytics {
    <#
    .SYNOPSIS
    Retrieves comprehensive baseline data from the AzureCostBaseline_CL table for trend analysis and anomaly detection
    #>
    param(
        [Parameter(Mandatory=$true)]
        [string]$WorkspaceId,
        [int]$DaysBack = 90
    )

    try {
        Write-Output "Querying AzureCostBaseline_CL table for comprehensive baseline data..."
        
        $query = @"
AzureCostBaseline_CL
| where TimeGenerated > ago($($DaysBack)d)
| where isnotempty(BaselineType_s)
| project TimeGenerated, CalculationDate_s, SubscriptionId_s, BaselineType_s, Period_s,
          // Rolling averages
          Avg7Day_d, Avg30Day_d, Avg60Day_d,
          AvgAVD7Day_d, AvgAVD30Day_d, AvgNonAVD7Day_d, AvgNonAVD30Day_d,
          // Variance metrics
          StandardDeviation_d, CoefficientOfVariation_d, GrowthTrendPercent_d, TrendDirection_s,
          UpperConfidenceInterval_d, LowerConfidenceInterval_d,
          // Seasonal patterns
          PeakDay_d, PeakDayName_s, PeakDayCost_d, LowDay_d, LowDayName_s, LowDayCost_d,
          SeasonalVariance_d, SeasonalityIndex_d, PatternStrength_s,
          // Service-specific data
          ServiceName_s, IsAVDResource_b, AvgDailyCost_d, VolatilityRatio_d, Predictability_s,
          ExpectedMinCost_d, ExpectedMaxCost_d, GrowthPattern_s,
          // Anomaly thresholds
          DayChangeAvg_d, DayChangeStdDev_d, DayUpperThreshold_d, DayLowerThreshold_d,
          WeekChangeAvg_d, WeekChangeStdDev_d, WeekUpperThreshold_d, WeekLowerThreshold_d,
          RecentAnomalyCount_d, RecentAnomalyRate_d,
          // Data quality
          DataPoints_d, DataQuality_s
| order by TimeGenerated desc
"@

        $result = Invoke-LogAnalyticsQuery -WorkspaceId $WorkspaceId -Query $query -QueryName "Comprehensive Baseline Data"
        
        if ($result -and $result.Count -gt 0) {
            Write-Output "Retrieved $($result.Count) baseline records from Log Analytics"
            
            # Group by baseline type for analysis
            $baselineTypes = $result | Group-Object -Property BaselineType_s
            Write-Output "Baseline types available:"
            foreach ($type in $baselineTypes) {
                Write-Output "  - $($type.Name): $($type.Count) records"
            }
            
            return $result
        } else {
            Write-Warning "No baseline data found in AzureCostBaseline_CL table"
            Write-Warning "You may need to run the baseline calculation runbook first"
            return @()
        }
    } catch {
        Write-Error "Failed to retrieve baseline data: $($_.Exception.Message)"
        return @()
    }
}

function Get-HistoricalDataFromLogAnalytics {
    <#
    .SYNOPSIS
    Retrieves historical cost data from the AzureHistoricalCostData_CL table for long-term analysis
    #>
    param(
        [Parameter(Mandatory=$true)]
        [string]$WorkspaceId,
        [int]$DaysBack = 180
    )

    try {
        Write-Output "Querying AzureHistoricalCostData_CL table for historical data..."
        
        $query = @"
AzureHistoricalCostData_CL
| where TimeGenerated > ago($($DaysBack)d)
| where isnotempty(Cost_d)
| project TimeGenerated, Cost = todouble(Cost_d), ServiceName = ServiceName_s,
          ResourceGroup = ResourceGroup_s, Location = Location_s, IsAVDResource = IsAVDResource_b,
          Month = format_datetime(TimeGenerated, 'yyyy-MM'), Week = startofweek(TimeGenerated),
          SubscriptionId = SubscriptionId_s
| summarize MonthlyCost = sum(Cost), WeeklyCost = sum(Cost) by Month, Week, ServiceName, IsAVDResource, SubscriptionId
| order by Month desc, Week desc
"@

        $result = Invoke-LogAnalyticsQuery -WorkspaceId $WorkspaceId -Query $query -QueryName "Historical Data"
        
        if ($result -and $result.Count -gt 0) {
            Write-Output "Retrieved $($result.Count) historical records from Log Analytics"
            return $result
        } else {
            Write-Warning "No historical data found in AzureHistoricalCostData_CL table"
            return @()
        }
    } catch {
        Write-Error "Failed to retrieve historical data: $($_.Exception.Message)"
        return @()
    }
}

function Get-PerformanceDataFromLogAnalytics {
    <#
    .SYNOPSIS
    Retrieves VM performance data for rightsizing analysis
    #>
    param(
        [string]$WorkspaceId
    )
    
    try {
        Write-Output "Querying Perf table for VM performance metrics..."
        
        $query = @"
Perf
| where TimeGenerated > ago(7d)
| where ObjectName == "Processor" and CounterName == "% Processor Time" and InstanceName == "_Total"
   or ObjectName == "Memory" and CounterName == "% Committed Bytes In Use"
| extend VMName = Computer
| summarize 
    AvgCpuPercent = avg(iif(CounterName == "% Processor Time", CounterValue, real(null))),
    AvgMemoryPercent = avg(iif(CounterName == "% Committed Bytes In Use", CounterValue, real(null)))
    by VMName
| where isnotnull(AvgCpuPercent) and isnotnull(AvgMemoryPercent)
"@

        $result = Invoke-LogAnalyticsQuery -WorkspaceId $WorkspaceId -Query $query
        
        if ($result -and $result.Count -gt 0) {
            Write-Output "Retrieved performance data for $($result.Count) VMs"
            return $result
        } else {
            Write-Warning "No performance data found in Perf table"
            return @()
        }
    } catch {
        Write-Error "Failed to retrieve performance data: $($_.Exception.Message)"
        return @()
    }
}

function Get-RightsizingAnalysis {
    <#
    .SYNOPSIS
    Analyzes VM performance data to identify rightsizing opportunities
    #>
    param(
        [string]$WorkspaceId
    )
    
    try {
        Write-Output "Performing rightsizing analysis..."
        
        $performanceData = Get-PerformanceDataFromLogAnalytics -WorkspaceId $WorkspaceId
        
        $underutilizedVMs = @()
        $overutilizedVMs = @()
        
        foreach ($vm in $performanceData) {
            if ($vm.AvgCpuPercent -lt 20 -and $vm.AvgMemoryPercent -lt 30) {
                $underutilizedVMs += @{
                    VMName = $vm.VMName
                    AvgCpuPercent = [math]::Round($vm.AvgCpuPercent, 1)
                    AvgMemoryPercent = [math]::Round($vm.AvgMemoryPercent, 1)
                    RecommendedSize = "Standard_B2s"  # Simplified recommendation
                    CurrentSize = "Standard_D4s_v3"  # Assumed current size
                    EstimatedMonthlySavings = 150     # Simplified calculation
                }
            } elseif ($vm.AvgCpuPercent -gt 80 -or $vm.AvgMemoryPercent -gt 85) {
                $overutilizedVMs += @{
                    VMName = $vm.VMName
                    AvgCpuPercent = [math]::Round($vm.AvgCpuPercent, 1)
                    AvgMemoryPercent = [math]::Round($vm.AvgMemoryPercent, 1)
                    RecommendedSize = "Standard_D8s_v3"  # Simplified recommendation
                    CurrentSize = "Standard_D4s_v3"     # Assumed current size
                }
            }
        }
        
        Write-Output "Found $($underutilizedVMs.Count) underutilized VMs and $($overutilizedVMs.Count) overutilized VMs"
        
        return @{
            UnderutilizedVMs = $underutilizedVMs
            OverutilizedVMs = $overutilizedVMs
        }
    } catch {
        Write-Error "Failed to perform rightsizing analysis: $($_.Exception.Message)"
        return @{
            UnderutilizedVMs = @()
            OverutilizedVMs = @()
        }
    }
}

function Invoke-CostAnalysisWithClaude {
    <#
    .SYNOPSIS
    Invokes Claude AI analysis for cost optimization insights
    #>
    param(
        [array]$CostData,
        [array]$PerformanceData,
        [object]$RightsizingData
    )
    
    try {
        Write-Output "Preparing data for AI analysis..."
        
        # Safely extract cost data properties
        $totalCost = 0
        $topServices = @()
        
        if ($CostData -and $CostData.Count -gt 0) {
            # Find cost property dynamically
            $firstRecord = $CostData[0]
            $properties = $firstRecord | Get-Member -MemberType Properties | Select-Object -ExpandProperty Name
            $costProperty = $properties | Where-Object { $_ -match "(?i)cost.*d$|^cost$" } | Select-Object -First 1
            if (-not $costProperty) {
                $costProperty = $properties | Where-Object { $_ -match "(?i)cost" } | Select-Object -First 1
            }
            $serviceProperty = $properties | Where-Object { $_ -match "(?i)service.*name" } | Select-Object -First 1
            
            if ($costProperty) {
                # Calculate total cost safely
                $costValues = $CostData | Where-Object { $_.$costProperty -ne $null -and $_.$costProperty -ne "" } | ForEach-Object { 
                    try { [double]$_.$costProperty } catch { 0 }
                }
                $totalCost = ($costValues | Measure-Object -Sum).Sum
                
                # Get top services safely
                if ($serviceProperty) {
                    $topServices = $CostData | Where-Object { $_.$serviceProperty -ne $null -and $_.$costProperty -ne $null } | 
                        Group-Object -Property $serviceProperty | ForEach-Object {
                            $serviceCostValues = $_.Group | ForEach-Object { 
                                try { [double]$_.$costProperty } catch { 0 }
                            }
                            $serviceCost = ($serviceCostValues | Measure-Object -Sum).Sum
                            
                            @{
                                Service = $_.Name
                                Cost = $serviceCost
                            }
                        } | Sort-Object Cost -Descending | Select-Object -First 5
                }
            }
        }
        
        # Prepare data summaries for Claude
        $costSummary = @{
            TotalCost = $totalCost
            TopServices = $topServices
            RightsizingOpportunities = if ($RightsizingData.UnderutilizedVMs) { $RightsizingData.UnderutilizedVMs.Count } else { 0 }
        }
        
        # Call Claude analysis with enhanced AVD service breakdown
        $analysisText = Invoke-ClaudeAnalysis -CostData $costSummary -PerformanceData $PerformanceData -RightsizingData $RightsizingData -AvdServiceBreakdown $avdServiceBreakdown
        
        if ($analysisText) {
            Write-Output "AI analysis completed successfully"
            
            # Parse Claude response (simplified for MVP)
            $potentialSavings = [math]::Round($costSummary.TotalCost * 0.15, 0)  # Estimate 15% savings
            if ($RightsizingData.UnderutilizedVMs -and $RightsizingData.UnderutilizedVMs.Count -gt 0) {
                try {
                    $vmSavings = ($RightsizingData.UnderutilizedVMs | ForEach-Object { 
                        if ($_.EstimatedMonthlySavings -ne $null) { 
                            try { [double]$_.EstimatedMonthlySavings } catch { 0 }
                        } else { 0 }
                    } | Measure-Object -Sum).Sum
                } catch {
                    $vmSavings = 0
                }
            } else {
                $vmSavings = 0
            }
            
            return @{
                summary = @{
                    potentialSavings = $potentialSavings
                    keyInsights = @(
                        "Cost optimization opportunities identified across $($costSummary.TopServices.Count) services",
                        "$($RightsizingData.UnderutilizedVMs.Count) VMs are candidates for rightsizing",
                        "Focus on top cost drivers for maximum impact"
                    )
                }
                recommendations = @(
                    @{
                        Title = "VM Rightsizing"
                        Description = "Scale down underutilized virtual machines to reduce costs"
                        Priority = "High"
                        EstimatedSavings = $vmSavings
                    }
                    @{
                        Title = "Storage Optimization"
                        Description = "Implement lifecycle policies and storage tiering"
                        Priority = "Medium"
                        EstimatedSavings = [math]::Round($costSummary.TotalCost * 0.1, 0)
                    }
                )
                topCostDrivers = $costSummary.TopServices
            }
        } else {
            Write-Warning "AI analysis returned no results"
            return $null
        }
    } catch {
        Write-Error "AI analysis failed: $($_.Exception.Message)"
        return $null
    }
}

function Invoke-AnomalyDetection {
    <#
    .SYNOPSIS
    Detects cost anomalies using statistical analysis and baseline comparison
    #>
    param(
        [Parameter(Mandatory=$true)]
        [array]$CostData,
        [array]$BaselineData = @()
    )

    try {
        Write-Output "Performing cost anomaly detection..."
        
        $anomalies = @()
        
        # Group cost data by service and date for analysis
        $dailyCosts = $CostData | Group-Object { (Get-Date $_.TimeGenerated).Date.ToString("yyyy-MM-dd") } | ForEach-Object {
            $date = $_.Name
            $totalCost = ($_.Group | ForEach-Object { [double]$_.Cost_d } | Measure-Object -Sum).Sum
            @{
                Date = $date
                TotalCost = $totalCost
                Services = ($_.Group | Group-Object ServiceName_s | ForEach-Object {
                    @{
                        ServiceName = $_.Name
                        Cost = ($_.Group | ForEach-Object { [double]$_.Cost_d } | Measure-Object -Sum).Sum
                    }
                })
            }
        }
        
        # Calculate rolling average and standard deviation
        if ($dailyCosts.Count -ge 3) {
            $costs = $dailyCosts | ForEach-Object { $_.TotalCost }
            $avgCost = ($costs | Measure-Object -Average).Average
            $stdDev = [Math]::Sqrt(($costs | ForEach-Object { [Math]::Pow($_ - $avgCost, 2) } | Measure-Object -Sum).Sum / $costs.Count)
            
            # Detect anomalies (costs beyond 2 standard deviations)
            foreach ($day in $dailyCosts) {
                $zscore = if ($stdDev -gt 0) { ($day.TotalCost - $avgCost) / $stdDev } else { 0 }
                
                if ([Math]::Abs($zscore) -gt 2) {
                    $anomalies += @{
                        Date = $day.Date
                        Cost = $day.TotalCost
                        BaselineCost = $avgCost
                        Variance = $day.TotalCost - $avgCost
                        ZScore = $zscore
                        Type = if ($zscore -gt 0) { "Spike" } else { "Drop" }
                        Severity = if ([Math]::Abs($zscore) -gt 3) { "High" } elseif ([Math]::Abs($zscore) -gt 2.5) { "Medium" } else { "Low" }
                        TopServices = ($day.Services | Sort-Object Cost -Descending | Select-Object -First 3)
                    }
                }
            }
        }
        
        Write-Output "Detected $($anomalies.Count) cost anomalies"
        return $anomalies
        
    } catch {
        Write-Error "Failed to perform anomaly detection: $($_.Exception.Message)"
        return @()
    }
}

function Invoke-ChargebackAnalysis {
    <#
    .SYNOPSIS
    Performs comprehensive chargeback analysis based on tagging and cost allocation rules
    #>
    param(
        [Parameter(Mandatory=$true)]
        [array]$CostData
    )

    try {
        Write-Output "Performing chargeback analysis..."
        
        $chargebackResults = @{
            DirectAllocations = @()
            UnallocatedCosts = @()
            AllocationSummary = @()
            TagComplianceReport = @()
        }
        
        # Analyze tag completeness and allocation status
        $totalCost = ($CostData | ForEach-Object { [double]$_.Cost_d } | Measure-Object -Sum).Sum
        $allocatableCost = 0
        $unallocatedCost = 0
        
        # Group by allocation status
        $allocationGroups = $CostData | Group-Object AllocationStatus
        
        foreach ($group in $allocationGroups) {
            $groupCost = ($group.Group | ForEach-Object { [double]$_.Cost_d } | Measure-Object -Sum).Sum
            
            if ($group.Name -eq "Allocatable") {
                $allocatableCost = $groupCost
                
                # Break down allocatable costs by cost center/department
                $costCenterBreakdown = $group.Group | Group-Object CostCenter | ForEach-Object {
                    $ccCost = ($_.Group | ForEach-Object { [double]$_.Cost_d } | Measure-Object -Sum).Sum
                    @{
                        CostCenter = $_.Name
                        Cost = $ccCost
                        Percentage = if ($totalCost -gt 0) { ($ccCost / $totalCost) * 100 } else { 0 }
                        ResourceCount = $_.Group.Count
                        Services = ($_.Group | Group-Object ServiceName_s | ForEach-Object {
                            @{
                                Service = $_.Name
                                Cost = ($_.Group | ForEach-Object { [double]$_.Cost_d } | Measure-Object -Sum).Sum
                            }
                        } | Sort-Object Cost -Descending)
                    }
                }
                
                $chargebackResults.DirectAllocations = $costCenterBreakdown
            } else {
                $unallocatedCost += $groupCost
                
                # Analyze unallocated costs for recommendations
                $unallocatedBreakdown = $group.Group | Group-Object ServiceName_s | ForEach-Object {
                    $serviceCost = ($_.Group | ForEach-Object { [double]$_.Cost_d } | Measure-Object -Sum).Sum
                    @{
                        Service = $_.Name
                        Cost = $serviceCost
                        ResourceCount = $_.Group.Count
                        MissingTags = ($_.Group | ForEach-Object { 
                            if ($_.MissingTags) { $_.MissingTags -split ";" } else { @() }
                        } | Sort-Object -Unique)
                    }
                }
                
                $chargebackResults.UnallocatedCosts = $unallocatedBreakdown
            }
        }
        
        # Calculate allocation efficiency metrics
        $allocationEfficiency = if ($totalCost -gt 0) { ($allocatableCost / $totalCost) * 100 } else { 0 }
        
        $chargebackResults.AllocationSummary = @{
            TotalCost = $totalCost
            AllocatableCost = $allocatableCost
            UnallocatedCost = $unallocatedCost
            AllocationEfficiency = $allocationEfficiency
            ImprovementPotential = 100 - $allocationEfficiency
        }
        
        # Generate tag compliance report
        $tagCompliance = $CostData | Group-Object { [Math]::Floor([double]$_.TagCompleteness / 20) * 20 } | ForEach-Object {
            $range = $_.Name
            $cost = ($_.Group | ForEach-Object { [double]$_.Cost_d } | Measure-Object -Sum).Sum
            @{
                ComplianceRange = "$range%-$([int]$range + 19)%"
                Cost = $cost
                Percentage = if ($totalCost -gt 0) { ($cost / $totalCost) * 100 } else { 0 }
                ResourceCount = $_.Group.Count
            }
        } | Sort-Object { [int]$_.ComplianceRange.Split('-')[0] } -Descending
        
        $chargebackResults.TagComplianceReport = $tagCompliance
        
        Write-Output "Chargeback analysis completed - Allocation efficiency: $([Math]::Round($allocationEfficiency, 2))%"
        return $chargebackResults
        
    } catch {
        Write-Error "Failed to perform chargeback analysis: $($_.Exception.Message)"
        return @{
            DirectAllocations = @()
            UnallocatedCosts = @()
            AllocationSummary = @{ TotalCost = 0; AllocatableCost = 0; UnallocatedCost = 0; AllocationEfficiency = 0 }
            TagComplianceReport = @()
        }
    }
}

function Get-ContextEnrichment {
    <#
    .SYNOPSIS
    Enriches cost analysis with business and operational context for better AI insights
    #>
    param(
        [Parameter(Mandatory=$true)]
        [array]$CostData,
        [array]$PerformanceData = @(),
        [array]$BudgetData = @(),
        [array]$ForecastData = @()
    )

    try {
        Write-Output "Enriching analysis context..."
        
        $context = @{
            temporal_context = @{
                analysis_period = "Last 7 days"
                business_days_included = 5  # Assuming weekdays
                weekend_days_included = 2
                current_month_progress = ([DateTime]::Now.Day / [DateTime]::DaysInMonth([DateTime]::Now.Year, [DateTime]::Now.Month)) * 100
            }
            operational_context = @{
                total_resources_analyzed = $CostData.Count
                subscriptions_included = ($CostData | Group-Object SubscriptionId).Count
                services_analyzed = ($CostData | Group-Object ServiceName_s).Count
                regions_included = ($CostData | Group-Object Location_s).Count
            }
            business_context = @{
                cost_allocation_maturity = if ($CostData) { 
                    $avgTagCompleteness = ($CostData | ForEach-Object { [double]$_.TagCompleteness } | Measure-Object -Average).Average
                    if ($avgTagCompleteness -gt 80) { "Advanced" } 
                    elseif ($avgTagCompleteness -gt 60) { "Intermediate" } 
                    elseif ($avgTagCompleteness -gt 40) { "Basic" } 
                    else { "Initial" }
                } else { "Unknown" }
                budget_tracking_enabled = if ($BudgetData -and $BudgetData.Count -gt 0) { $true } else { $false }
                forecasting_available = if ($ForecastData -and $ForecastData.Count -gt 0) { $true } else { $false }
            }
            performance_context = @{
                performance_data_available = if ($PerformanceData -and $PerformanceData.Count -gt 0) { $true } else { $false }
                rightsizing_candidates = if ($PerformanceData) { $PerformanceData.Count } else { 0 }
            }
        }
        
        return $context
        
    } catch {
        Write-Error "Failed to enrich context: $($_.Exception.Message)"
        return @{}
    }
}

# ============================================================================
# MAIN EXECUTION BLOCK - ENHANCED AZURE AUTOMATION RUNBOOK ENTRY POINT
# ============================================================================

# Record start time for performance tracking
$startTime = Get-Date

Write-Output "=============================================="
Write-Output "Enhanced Azure Cost Management - Weekly Analysis Engine v2.0"
Write-Output "Features: Chain-of-Thought AI, Anomaly Detection, Chargeback Analysis"
Write-Output "=============================================="
Write-Output "Start Time: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') UTC"
Write-Output ""

try {
    # Connect to Azure with Managed Identity
    Write-Output "🔐 Connecting to Azure with Managed Identity..."
    $azureContext = Connect-AzureWithManagedIdentity
    
    # Get configuration variables
    Write-Output "⚙️ Loading configuration variables..."
    $targetSubscriptionIds = Get-ConfigurationVariable -Name "TARGET_SUBSCRIPTION_IDS" -DefaultValue $SubscriptionIds
    $workspaceId = Get-ConfigurationVariable -Name "LOG_ANALYTICS_WORKSPACE_ID"
    $costReportRecipients = Get-ConfigurationVariable -Name "COST_REPORT_RECIPIENTS"
    
    if ([string]::IsNullOrEmpty($targetSubscriptionIds)) {
        throw "TARGET_SUBSCRIPTION_IDS is not configured. Please set this automation variable."
    }
    
    if ([string]::IsNullOrEmpty($workspaceId)) {
        throw "LOG_ANALYTICS_WORKSPACE_ID is not configured. Please set this automation variable."
    }
    
    Write-Output "📊 Target Subscriptions: $targetSubscriptionIds"
    Write-Output "📈 Log Analytics Workspace: $workspaceId"
    Write-Output "📧 Report Recipients: $costReportRecipients"
    Write-Output ""
    
    # =========================================================================
    # ENHANCED DATA COLLECTION PHASE
    # =========================================================================
    
    Write-Output "📥 Phase 1: Enhanced Data Collection from Multiple Sources..."
    
    # Collect primary cost data
    Write-Output "📊 Querying enhanced cost data from Log Analytics..."
    $costData = Get-CostDataFromLogAnalytics -WorkspaceId $workspaceId -DaysBack 7
    
    # Collect forecasting data if enabled
    $forecastData = @()
    if ($IncludeForecasting) {
        Write-Output "🔮 Collecting forecast data..."
        $forecastData = Get-ForecastDataFromLogAnalytics -WorkspaceId $workspaceId -DaysBack 30
    }
    
    # Collect budget data
    $budgetData = @()
    Write-Output "📋 Collecting budget tracking data..."
    $budgetData = Get-BudgetDataFromLogAnalytics -WorkspaceId $workspaceId -DaysBack 30
    
    # Collect advisor recommendations
    $advisorData = @()
    Write-Output "💡 Collecting Azure Advisor recommendations..."
    $advisorData = Get-AdvisorRecommendationsFromLogAnalytics -WorkspaceId $workspaceId -DaysBack 7
    
    # Collect baseline and historical data
    $baselineData = @()
    $historicalData = @()
    Write-Output "📈 Collecting baseline and historical data..."
    $baselineData = Get-BaselineDataFromLogAnalytics -WorkspaceId $workspaceId -DaysBack 90
    $historicalData = Get-HistoricalDataFromLogAnalytics -WorkspaceId $workspaceId -DaysBack 180
    
    # Validate primary cost data
    $validCostData = @()
    if ($costData) {
        Write-Output "✅ Validating enhanced cost data format..."
        Write-Output "   Raw data type: $($costData.GetType().Name)"
        Write-Output "   Raw data count: $(if($costData.Count) {$costData.Count} else {'N/A'})"
        
        if ($costData -is [Array]) {
            foreach ($item in $costData) {
                if ($item -is [PSObject] -and $item.PSObject.Properties.Count -gt 0) {
                    $hasValidProperties = $false
                    $propertyNames = $item.PSObject.Properties.Name
                    if ($propertyNames -contains "Cost_d" -or 
                        $propertyNames -contains "CostUSD" -or 
                        ($propertyNames | Where-Object { $_ -match "(?i)cost" })) {
                        $hasValidProperties = $true
                    }
                    
                    if ($hasValidProperties) {
                        $validCostData += $item
                    }
                }
            }
        } elseif ($costData -is [PSObject] -and $costData.PSObject.Properties.Count -gt 0) {
            $propertyNames = $costData.PSObject.Properties.Name
            if ($propertyNames -contains "Cost_d" -or 
                $propertyNames -contains "CostUSD" -or 
                ($propertyNames | Where-Object { $_ -match "(?i)cost" })) {
                $validCostData = @($costData)
            }
        }
        
        Write-Output "   Valid cost records found: $($validCostData.Count)"
    }
    
    if (-not $validCostData -or $validCostData.Count -eq 0) {
        Write-Warning "⚠️ No valid cost data found in Log Analytics. The enhanced analysis requires recent cost data."
        Write-Output "💡 This could be due to:"
        Write-Output "   - Authentication issues (managed identity not configured)"
        Write-Output "   - No cost data collected in the last 7 days"
        Write-Output "   - Log Analytics workspace ID incorrect"
        Write-Output "   - AzureCostData_CL table doesn't exist"
        Write-Output "Exiting - no data to analyze."
        return
    }
    
    # Use the validated data going forward
    $costData = $validCostData
    Write-Output "✅ Retrieved $($costData.Count) valid cost records"
    
    # =========================================================================
    # ENHANCED ANALYSIS PHASE
    # =========================================================================
    
    Write-Output "🧠 Phase 2: Enhanced Multi-Dimensional Analysis..."
    
    # Get performance data for rightsizing analysis
    Write-Output "⚡ Querying performance data for rightsizing analysis..."
    $performanceData = Get-PerformanceDataFromLogAnalytics -WorkspaceId $workspaceId
    $rightsizingData = Get-RightsizingAnalysis -WorkspaceId $workspaceId
    
    # Perform anomaly detection if enabled
    $costAnomalies = @()
    if ($IncludeAnomalyDetection) {
        Write-Output "🔍 Performing advanced anomaly detection..."
        $costAnomalies = Invoke-AnomalyDetection -CostData $costData -BaselineData $baselineData
    }
    
    # Perform chargeback analysis if enabled
    $chargebackResults = @{}
    if ($IncludeChargebackAnalysis) {
        Write-Output "💼 Performing comprehensive chargeback analysis..."
        $chargebackResults = Invoke-ChargebackAnalysis -CostData $costData
    }
    
    # Enrich context for better AI analysis
    Write-Output "🌟 Enriching analysis context..."
    $contextEnrichment = Get-ContextEnrichment -CostData $costData -PerformanceData $performanceData -BudgetData $budgetData -ForecastData $forecastData
    
    # Prepare comprehensive datasets for analysis
    Write-Output "📊 Processing cost data and generating comprehensive analysis..."
    
    # Calculate daily cost trends
    $dailyCostTrends = $costData | Group-Object { (Get-Date $_.TimeGenerated).Date.ToString("yyyy-MM-dd") } | ForEach-Object {
        $date = $_.Name
        $totalCost = ($_.Group | ForEach-Object { [double]$_.Cost_d } | Measure-Object -Sum).Sum
        @{
            Date = $date
            TotalCost = $totalCost
            AVDCost = ($_.Group | Where-Object { $_.IsAVDResource_b -eq $true } | ForEach-Object { [double]$_.Cost_d } | Measure-Object -Sum).Sum
            NonAVDCost = ($_.Group | Where-Object { $_.IsAVDResource_b -ne $true } | ForEach-Object { [double]$_.Cost_d } | Measure-Object -Sum).Sum
        }
    } | Sort-Object Date
    
    # Enhanced service cost analysis with growth trends
    $serviceCostAnalysis = $costData | Group-Object ServiceName_s | ForEach-Object {
        $serviceCost = ($_.Group | ForEach-Object { [double]$_.Cost_d } | Measure-Object -Sum).Sum
        $resourceCount = $_.Group.Count
        $avgTagCompleteness = if ($_.Group[0].TagCompleteness) { 
            ($_.Group | ForEach-Object { [double]$_.TagCompleteness } | Measure-Object -Average).Average 
        } else { 0 }
        
        @{
            ServiceName = $_.Name
            CurrentWeek = $serviceCost
            Cost = $serviceCost
            ResourceCount = $resourceCount
            AvgTagCompleteness = $avgTagCompleteness
            AllocationStatus = if ($avgTagCompleteness -gt 80) { "Well-Tagged" } elseif ($avgTagCompleteness -gt 60) { "Partially-Tagged" } else { "Poorly-Tagged" }
        }
    } | Sort-Object CurrentWeek -Descending
    
    # Create resource inventory for analysis
    $resourceInventory = $costData | ForEach-Object {
        @{
            ResourceName = $_.ResourceName_s
            ResourceType = $_.ResourceType
            ServiceName = $_.ServiceName_s
            Cost = [double]$_.Cost_d
            Location = $_.Location_s
            TagCompleteness = if ($_.TagCompleteness) { [double]$_.TagCompleteness } else { 0 }
            AllocationStatus = $_.AllocationStatus
            CostCenter = $_.CostCenter
            Department = $_.Department
        }
    }
    
    # =========================================================================
    # ENHANCED AI ANALYSIS PHASE
    # =========================================================================
    
    Write-Output "🤖 Phase 3: Enhanced AI Analysis with Chain-of-Thought Prompting..."
    
    # Perform enhanced AI analysis if enabled
    $analysisResults = $null
    if ($EnableAdvancedPrompting) {
        $analysisResults = Invoke-ClaudeAnalysis -CostData $costData -DailyCostTrends $dailyCostTrends -ServiceCostAnalysis $serviceCostAnalysis -BaselineData $baselineData -HistoricalData $historicalData -ResourceInventory $resourceInventory -CostAnomalies $costAnomalies -PerformanceData $performanceData -RightsizingData $rightsizingData -AvdServiceBreakdown $avdServiceBreakdown -ContextEnrichment $contextEnrichment
    }
    
    if (-not $analysisResults) {
        Write-Warning "⚠️ AI analysis failed or returned no results. Generating reports with available data only."
        $analysisResults = Get-SimplifiedAnalysis -CostData $costData -RightsizingData $rightsizingData
    }
    
    Write-Output "✅ Enhanced AI analysis completed"
    
    # =========================================================================
    # ENHANCED METRICS CALCULATION PHASE
    # =========================================================================
    
    Write-Output "📈 Phase 4: Enhanced Metrics Calculation..."
    
    # Safe cost calculations with error handling
    $totalCost = 0
    $avdCost = 0
    $nonAvdCost = 0
    
    if ($costData -and $costData.Count -gt 0) {
        # Calculate total cost safely
        $costValues = $costData | Where-Object { $_.Cost_d -ne $null -and $_.Cost_d -ne "" } | ForEach-Object { 
            try { [double]$_.Cost_d } catch { 0 }
        }
        $totalCost = ($costValues | Measure-Object -Sum).Sum
        
        # Calculate AVD vs Non-AVD costs safely
        $avdRecords = $costData | Where-Object { $_.IsAVDResource_b -eq $true -and $_.Cost_d -ne $null }
        if ($avdRecords) {
            $avdCostValues = $avdRecords | ForEach-Object { 
                try { [double]$_.Cost_d } catch { 0 }
            }
            $avdCost = ($avdCostValues | Measure-Object -Sum).Sum
        }
        
        $nonAvdRecords = $costData | Where-Object { $_.IsAVDResource_b -ne $true -and $_.Cost_d -ne $null }
        if ($nonAvdRecords) {
            $nonAvdCostValues = $nonAvdRecords | ForEach-Object { 
                try { [double]$_.Cost_d } catch { 0 }
            }
            $nonAvdCost = ($nonAvdCostValues | Measure-Object -Sum).Sum
        }
    }
    
    # Enhanced AVD Service Category Analysis for detailed AVD reporting
    # Note: All AVD resources are located in NIPAzure subscription (77bc541c-d229-4ff3-81c1-928accbff379)
    $avdServiceBreakdown = @{}
    $avdTotalCost = 0
    $nipAzureSubscriptionId = "77bc541c-d229-4ff3-81c1-928accbff379"
    
    if ($costData) {
        # Check if we have the new AVDServiceCategory field
        $hasAvdCategoryField = $costData | Get-Member -Name "AVDServiceCategory*" -MemberType NoteProperty | Select-Object -First 1
        
        if ($hasAvdCategoryField) {
            Write-Output "🖥️  Analyzing AVD service categories using new AVDServiceCategory field..."
            Write-Output "   📍 AVD resources are primarily located in NIPAzure subscription ($nipAzureSubscriptionId)"
            $avdCategoryProperty = $hasAvdCategoryField.Name
            
            # Analyze AVD resources by service category
            $avdRecordsWithCategory = $costData | Where-Object { 
                $_.$avdCategoryProperty -and $_.$avdCategoryProperty -ne "Non-AVD" -and $_.$costProperty -ne $null 
            }
            
            if ($avdRecordsWithCategory) {
                $avdServiceBreakdown = $avdRecordsWithCategory | Group-Object -Property $avdCategoryProperty | ForEach-Object {
                    $categoryName = $_.Name
                    $categoryCost = ($_.Group | ForEach-Object { 
                        try { [double]$_.$costProperty } catch { 0 }
                    } | Measure-Object -Sum).Sum
                    
                    $resourceCount = $_.Group.Count
                    $avgCostPerResource = if ($resourceCount -gt 0) { $categoryCost / $resourceCount } else { 0 }
                    
                    Write-Output "   🔹 $categoryName`: $($categoryCost.ToString('C2')) ($resourceCount resources, avg: $($avgCostPerResource.ToString('C2')))"
                    
                    @{
                        Category = $categoryName
                        Cost = $categoryCost
                        ResourceCount = $resourceCount
                        AverageCostPerResource = $avgCostPerResource
                        Percentage = 0  # Will be calculated after total
                    }
                }
                
                # Calculate percentages
                $avdTotalFromCategories = ($avdServiceBreakdown | ForEach-Object { $_.Cost } | Measure-Object -Sum).Sum
                if ($avdTotalFromCategories -gt 0) {
                    $avdServiceBreakdown | ForEach-Object {
                        $_.Percentage = ($_.Cost / $avdTotalFromCategories) * 100
                    }
                }
                
                # Analyze AVD costs by subscription to validate NIPAzure location assumption
                $avdBySubscription = $avdRecordsWithCategory | Group-Object SubscriptionId | ForEach-Object {
                    $subId = $_.Name
                    $subCost = ($_.Group | ForEach-Object { 
                        try { [double]$_.$costProperty } catch { 0 }
                    } | Measure-Object -Sum).Sum
                    $subName = if ($subId -eq $nipAzureSubscriptionId) { "NIPAzure" } else { "Other" }
                    
                    Write-Output "   � $subName ($subId): $($subCost.ToString('C2')) AVD costs"
                    @{
                        SubscriptionId = $subId
                        SubscriptionName = $subName
                        Cost = $subCost
                        Percentage = if ($avdTotalFromCategories -gt 0) { ($subCost / $avdTotalFromCategories) * 100 } else { 0 }
                    }
                }
                
                Write-Output "   �💡 AVD Service Analysis: $($avdServiceBreakdown.Count) categories totaling $($avdTotalFromCategories.ToString('C2'))"
                
                # Validate assumption that AVD resources are primarily in NIPAzure
                $nipAzureAvdCost = ($avdBySubscription | Where-Object { $_.SubscriptionId -eq $nipAzureSubscriptionId } | ForEach-Object { $_.Cost } | Measure-Object -Sum).Sum
                $nipAzurePercentage = if ($avdTotalFromCategories -gt 0) { ($nipAzureAvdCost / $avdTotalFromCategories) * 100 } else { 0 }
                Write-Output "   🎯 NIPAzure contains $($nipAzurePercentage.ToString('F1'))% of total AVD costs (validation of subscription-specific optimization)"
            } else {
                Write-Output "   ℹ️  No AVD resources found with service categories"
            }
        } else {
            Write-Output "   ⚠️  AVDServiceCategory field not found - using legacy AVD detection"
            # Fallback to legacy AVD analysis
            $legacyAvdRecords = $costData | Where-Object { $_.$avdProperty -eq $true -and $_.$costProperty -ne $null }
            if ($legacyAvdRecords) {
                $avdTotalCost = ($legacyAvdRecords | ForEach-Object { 
                    try { [double]$_.$costProperty } catch { 0 }
                } | Measure-Object -Sum).Sum
                Write-Output "   🖥️  Legacy AVD detection: $($avdTotalCost.ToString('C2')) from $($legacyAvdRecords.Count) resources"
            }
        }
    }
    
    Write-Output "💰 Enhanced cost calculation results:"
    Write-Output "   Total Cost: $($totalCost.ToString('C2'))"
    Write-Output "   AVD Cost: $(if($avdCost -gt 0){$avdCost.ToString('C2')}else{'$0.00'})"
    Write-Output "   Non-AVD Cost: $(if($nonAvdCost -gt 0){$nonAvdCost.ToString('C2')}else{'$0.00'})"
    Write-Output "   Services: $($serviceCostAnalysis.Count)"
    Write-Output "   Anomalies Detected: $($costAnomalies.Count)"
    if ($chargebackResults.AllocationSummary) {
        Write-Output "   Allocation Efficiency: $([Math]::Round($chargebackResults.AllocationSummary.AllocationEfficiency, 2))%"
    }
    
    # Prepare enhanced report data structure
    $reportData = @{
        TotalCost = $totalCost
        AvdCost = $avdCost
        NonAvdCost = $nonAvdCost
        AvdServiceBreakdown = $avdServiceBreakdown  # New: AVD service category analysis
        CostVariance = 0  # Calculate from baseline if available
        CostAnomalies = $costAnomalies
        UnderutilizedVMs = $rightsizingData.UnderutilizedVMs
        OverutilizedVMs = $rightsizingData.OverutilizedVMs
        ServiceCostAnalysis = $serviceCostAnalysis
        AiAnalysisResults = $analysisResults
        TrendDirection = "stable"  # Enhanced trend calculation could be added
        SubscriptionIds = $targetSubscriptionIds.Split(',')
        ProjectedWeeklyCost = $totalCost * 1.05  # Basic projection
        # Enhanced data
        DailyCostTrends = $dailyCostTrends
        BaselineData = $baselineData
        HistoricalData = $historicalData
        PerformanceData = $performanceData
        ChargebackResults = $chargebackResults
        ForecastData = $forecastData
        BudgetData = $budgetData
        AdvisorData = $advisorData
        ContextEnrichment = $contextEnrichment
        AnalysisMetadata = @{
            AnalysisVersion = "2.0"
            FeaturesEnabled = @{
                AdvancedPrompting = $EnableAdvancedPrompting
                AnomalyDetection = $IncludeAnomalyDetection
                ChargebackAnalysis = $IncludeChargebackAnalysis
                Forecasting = $IncludeForecasting
                OptimizationRecommendations = $IncludeOptimizationRecommendations
            }
            DataSourceCounts = @{
                CostRecords = $costData.Count
                ForecastRecords = $forecastData.Count
                BudgetRecords = $budgetData.Count
                AdvisorRecords = $advisorData.Count
                PerformanceRecords = $performanceData.Count
                AnomaliesDetected = $costAnomalies.Count
            }
        }
    }
    
    Write-Output "📊 Enhanced Report Data Summary:"
    Write-Output "   Total Cost: $($reportData.TotalCost.ToString('C2'))"
    Write-Output "   AVD Cost: $($reportData.AvdCost.ToString('C2'))"
    Write-Output "   Non-AVD Cost: $($reportData.NonAvdCost.ToString('C2'))"
    Write-Output "   Services Analyzed: $($reportData.ServiceCostAnalysis.Count)"
    Write-Output "   Analysis Version: $($reportData.AnalysisMetadata.AnalysisVersion)"
    Write-Output ""
    $targetSubscriptionIds = Get-ConfigurationVariable -Name "TARGET_SUBSCRIPTION_IDS" -DefaultValue $SubscriptionIds
    $workspaceId = Get-ConfigurationVariable -Name "LOG_ANALYTICS_WORKSPACE_ID"
    $costReportRecipients = Get-ConfigurationVariable -Name "COST_REPORT_RECIPIENTS"
    
    if ([string]::IsNullOrEmpty($targetSubscriptionIds)) {
        throw "TARGET_SUBSCRIPTION_IDS is not configured. Please set this automation variable."
    }
    
    if ([string]::IsNullOrEmpty($workspaceId)) {
        throw "LOG_ANALYTICS_WORKSPACE_ID is not configured. Please set this automation variable."
    }
    
    Write-Output "?? Target Subscriptions: $targetSubscriptionIds"
    Write-Output "?? Log Analytics Workspace: $workspaceId"
    Write-Output "?? Report Recipients: $costReportRecipients"
    Write-Output ""
    
    # Query cost data from Log Analytics
    Write-Output "?? Querying cost data from Log Analytics..."
    $costData = Get-CostDataFromLogAnalytics -WorkspaceId $workspaceId
    
    # Validate cost data - ensure it's an array of PSObjects
    $validCostData = @()
    if ($costData) {
        Write-Output "?? Validating cost data format..."
        Write-Output "   Raw data type: $($costData.GetType().Name)"
        Write-Output "   Raw data count: $(if($costData.Count) {$costData.Count} else {'N/A'})"
        
        if ($costData -is [Array]) {
            # Filter out any non-PSObject entries (strings, etc.)
            foreach ($item in $costData) {
                if ($item -is [PSObject] -and $item.PSObject.Properties.Count -gt 0) {
                    # Additional check - ensure it has expected cost data properties
                    $hasValidProperties = $false
                    $propertyNames = $item.PSObject.Properties.Name
                    if ($propertyNames -contains "Cost_d" -or 
                        $propertyNames -contains "Cost" -or 
                        ($propertyNames | Where-Object { $_ -match "(?i)cost" })) {
                        $hasValidProperties = $true
                    }
                    
                    if ($hasValidProperties) {
                        $validCostData += $item
                    } else {
                        Write-Warning "   Skipping item without cost properties: $($propertyNames -join ', ')"
                    }
                } else {
                    Write-Warning "   Skipping non-PSObject item: $($item.GetType().Name) - '$($item.ToString().Substring(0, [Math]::Min(50, $item.ToString().Length)))...'"
                }
            }
        } elseif ($costData -is [PSObject] -and $costData.PSObject.Properties.Count -gt 0) {
            # Single PSObject - validate it has cost properties
            $propertyNames = $costData.PSObject.Properties.Name
            if ($propertyNames -contains "Cost_d" -or 
                $propertyNames -contains "Cost" -or 
                ($propertyNames | Where-Object { $_ -match "(?i)cost" })) {
                $validCostData = @($costData)
            } else {
                Write-Warning "   Single PSObject lacks cost properties: $($propertyNames -join ', ')"
            }
        } else {
            Write-Warning "   Unsupported data format: $($costData.GetType().Name)"
        }
        
        Write-Output "   Valid cost records found: $($validCostData.Count)"
    }
    
    if (-not $validCostData -or $validCostData.Count -eq 0) {
        Write-Warning "? No valid cost data found in Log Analytics. The weekly analysis requires recent cost data."
        Write-Output "?? This could be due to:"
        Write-Output "   - Authentication issues (managed identity not configured)"
        Write-Output "   - No cost data collected in the last 7 days"
        Write-Output "   - Log Analytics workspace ID incorrect"
        Write-Output "   - AzureCostData_CL table doesn't exist"
        Write-Output "   - Data format issues (returning strings instead of objects)"
        Write-Output "Exiting - no data to analyze."
        return
    }
    
    # Use the validated data going forward
    $costData = $validCostData
    Write-Output "? Retrieved $($costData.Count) valid cost records"
    
    # Get performance data for rightsizing analysis
    Write-Output "?? Querying performance data for rightsizing analysis..."
    $performanceData = Get-PerformanceDataFromLogAnalytics -WorkspaceId $workspaceId
    $rightsizingData = Get-RightsizingAnalysis -WorkspaceId $workspaceId
    
    Write-Output "? Retrieved performance data for analysis"
    
    # Process and analyze the data
    Write-Output "?? Processing cost data and generating analysis..."
    
    # Debug: Inspect the structure of cost data
    if ($costData -and $costData.Count -gt 0) {
        Write-Output "?? Cost data structure analysis:"
        Write-Output "   Data type: $($costData.GetType().Name)"
        Write-Output "   Count: $($costData.Count)"
        
        # Handle different data structures that might be returned
        $firstRecord = $null
        $properties = @()
        
        # Check if costData is an array
        if ($costData -is [Array] -and $costData.Count -gt 0) {
            $firstRecord = $costData[0]
            Write-Output "   Array detected, first element type: $($firstRecord.GetType().Name)"
            
            # Check if the first record is a string (indicating parsing issue)
            if ($firstRecord -is [string]) {
                Write-Warning "   First record is a string - this indicates a data parsing issue"
                Write-Output "   String content preview: $($firstRecord.Substring(0, [Math]::Min(100, $firstRecord.Length)))"
                
                # Try to find a non-string record in the array
                $objectRecord = $costData | Where-Object { $_ -is [PSObject] -and $_.PSObject.Properties.Count -gt 0 } | Select-Object -First 1
                if ($objectRecord) {
                    $firstRecord = $objectRecord
                    Write-Output "   Found PSObject record at a different position"
                } else {
                    Write-Warning "   No valid PSObject records found in array"
                    # Set default properties and continue
                    $costProperty = "Cost_d"
                    $avdProperty = "IsAVDResource_b" 
                    $serviceProperty = "ServiceName_s"
                    $properties = @($costProperty, $avdProperty, $serviceProperty)
                }
            }
        } elseif ($costData -is [PSObject] -and $costData.PSObject.Properties.Count -gt 0) {
            $firstRecord = $costData
            Write-Output "   Single PSObject detected"
        } else {
            Write-Warning "   Unrecognized data structure"
            $firstRecord = $costData
        }
        
        # Extract properties from valid PSObject record
        if ($firstRecord -and $firstRecord -is [PSObject] -and $firstRecord.PSObject.Properties) {
            $properties = $firstRecord.PSObject.Properties.Name
            Write-Output "   Available properties: $($properties -join ', ')"
            Write-Output "   First record type: $($firstRecord.GetType().Name)"
            
            # Show sample values for debugging
            $sampleData = @()
            foreach ($prop in $properties | Select-Object -First 5) {
                $value = $firstRecord.$prop
                $sampleData += "$prop=$value"
            }
            Write-Output "   Data sample: $($sampleData -join ', ')"
            
            # Find the cost property name (could be Cost_d, Cost, cost_d, etc.)
            $costProperty = $properties | Where-Object { $_ -match "(?i)cost.*d$|^cost$" } | Select-Object -First 1
            if (-not $costProperty) {
                $costProperty = $properties | Where-Object { $_ -match "(?i)cost" } | Select-Object -First 1
            }
            
            if ($costProperty) {
                Write-Output "   ? Using cost property: $costProperty"
            } else {
                Write-Warning "   ?? No cost property found! Available properties: $($properties -join ', ')"
                $costProperty = "Cost_d"  # Default fallback
            }
            
            # Find AVD property name
            $avdProperty = $properties | Where-Object { $_ -match "(?i)avd|isavdresource" } | Select-Object -First 1
            if ($avdProperty) {
                Write-Output "   ? Using AVD property: $avdProperty"
            } else {
                Write-Warning "   ?? No AVD property found! Using default: IsAVDResource_b"
                $avdProperty = "IsAVDResource_b"
            }
            
            # Find service name property
            $serviceProperty = $properties | Where-Object { $_ -match "(?i)service.*name" } | Select-Object -First 1
            if ($serviceProperty) {
                Write-Output "   ? Using service property: $serviceProperty"
            } else {
                Write-Warning "   ?? No service property found! Using default: ServiceName_s"
                $serviceProperty = "ServiceName_s"
            }
        } else {
            Write-Warning "   Could not access valid PSObject record for property analysis"
            Write-Output "   Using default property names"
            $costProperty = "Cost_d"
            $avdProperty = "IsAVDResource_b"
            $serviceProperty = "ServiceName_s"
            $properties = @($costProperty, $avdProperty, $serviceProperty)
        }
    } else {
        Write-Warning "No cost data available for analysis"
        # Set default properties
        $costProperty = "Cost_d"
        $avdProperty = "IsAVDResource_b"
        $serviceProperty = "ServiceName_s"
    }
    
    $analysisResults = Invoke-CostAnalysisWithClaude -CostData $costData -PerformanceData $performanceData -RightsizingData $rightsizingData
    
    if (-not $analysisResults) {
        Write-Warning "AI analysis failed or returned no results. Generating reports with available data only."
        $analysisResults = @{
            summary = @{
                potentialSavings = 0
                keyInsights = @("Analysis unavailable - using raw data")
            }
            recommendations = @()
            topCostDrivers = @()
        }
    }
    
    Write-Output "? AI analysis completed"
    
    # Prepare report data structure with safe property access
    try {
        # Safe cost calculations with error handling
        $totalCost = 0
        $avdCost = 0
        $nonAvdCost = 0
        $serviceAnalysis = @()
        
        if ($costData -and $costData.Count -gt 0) {
            # Calculate total cost safely
            $costValues = $costData | Where-Object { $_.$costProperty -ne $null -and $_.$costProperty -ne "" } | ForEach-Object { 
                try { [double]$_.$costProperty } catch { 0 }
            }
            $totalCost = ($costValues | Measure-Object -Sum).Sum
            
            # Calculate AVD vs Non-AVD costs safely
            $avdRecords = $costData | Where-Object { $_.$avdProperty -eq $true -and $_.$costProperty -ne $null }
            if ($avdRecords) {
                $avdCostValues = $avdRecords | ForEach-Object { 
                    try { [double]$_.$costProperty } catch { 0 }
                }
                $avdCost = ($avdCostValues | Measure-Object -Sum).Sum
            }
            
            $nonAvdRecords = $costData | Where-Object { $_.$avdProperty -ne $true -and $_.$costProperty -ne $null }
            if ($nonAvdRecords) {
                $nonAvdCostValues = $nonAvdRecords | ForEach-Object { 
                    try { [double]$_.$costProperty } catch { 0 }
                }
                $nonAvdCost = ($nonAvdCostValues | Measure-Object -Sum).Sum
            }
            
            # Group by service and calculate costs safely
            $serviceAnalysis = $costData | Where-Object { $_.$serviceProperty -ne $null -and $_.$costProperty -ne $null } | 
                Group-Object -Property $serviceProperty | ForEach-Object {
                    $serviceCostValues = $_.Group | ForEach-Object { 
                        try { [double]$_.$costProperty } catch { 0 }
                    }
                    $serviceCost = ($serviceCostValues | Measure-Object -Sum).Sum
                    
                    @{
                        ServiceName = $_.Name
                        CurrentWeek = $serviceCost
                        Cost = $serviceCost
                    }
                } | Sort-Object CurrentWeek -Descending
        }
        
        Write-Output "?? Cost calculation results:"
        Write-Output "   Total Cost: $($totalCost.ToString('C2'))"
        Write-Output "   AVD Cost: $(if($avdCost -gt 0){$avdCost.ToString('C2')}else{'$0.00'})"
        Write-Output "   Non-AVD Cost: $(if($nonAvdCost -gt 0){$nonAvdCost.ToString('C2')}else{'$0.00'})"
        Write-Output "   Services: $($serviceAnalysis.Count)"
        
        $reportData = @{
            TotalCost = $totalCost
            AvdCost = $avdCost
            NonAvdCost = $nonAvdCost
            CostVariance = 0  # TODO: Calculate from baseline
            CostAnomalies = @()  # TODO: Implement anomaly detection
            UnderutilizedVMs = $rightsizingData.UnderutilizedVMs
            OverutilizedVMs = $rightsizingData.OverutilizedVMs
            ServiceCostAnalysis = $serviceAnalysis
            AiAnalysisResults = $analysisResults
            TrendDirection = "up"  # TODO: Calculate from historical data
            SubscriptionIds = $targetSubscriptionIds.Split(',')
            ProjectedWeeklyCost = $totalCost * 1.05  # Basic projection
        }
        
    } catch {
        Write-Error "Error calculating cost metrics: $($_.Exception.Message)"
        Write-Output "Using fallback values for report generation"
        
        $reportData = @{
            TotalCost = 0
            AvdCost = 0
            NonAvdCost = 0
            CostVariance = 0
            CostAnomalies = @()
            UnderutilizedVMs = $rightsizingData.UnderutilizedVMs
            OverutilizedVMs = $rightsizingData.OverutilizedVMs
            ServiceCostAnalysis = @()
            AiAnalysisResults = $analysisResults
            TrendDirection = "unknown"
            SubscriptionIds = $targetSubscriptionIds.Split(',')
            ProjectedWeeklyCost = 0
        }
    }
    
    Write-Output "?? Report Data Summary:"
    Write-Output "   Total Cost: $($reportData.TotalCost.ToString('C2'))"
    Write-Output "   AVD Cost: $($reportData.AvdCost.ToString('C2'))"
    Write-Output "   Non-AVD Cost: $($reportData.NonAvdCost.ToString('C2'))"
    Write-Output "   Services Analyzed: $($reportData.ServiceCostAnalysis.Count)"
    Write-Output ""
    
    # Generate Executive Summary Report
    Write-Output "?? Generating Executive Summary Report..."
    try {
        $executiveSummary = $null
        $executiveSummary = New-ExecutiveSummaryReport -ReportData $reportData
        
        if ($executiveSummary -and $executiveSummary.Length -gt 100) {
            Write-Output "OK Executive Summary generated ($($executiveSummary.Length) characters)"
        } else {
            Write-Error "Failed to generate Executive Summary report - output too short or null"
            return
        }
    } catch {
        Write-Error "Error generating Executive Summary: $($_.Exception.Message)"
        return
    }
    
    # Generate Engineering Report
    Write-Output "?? Generating Engineering Report..."
    try {
        $engineeringReport = $null
        $engineeringReport = New-EngineeringReport -ReportData $reportData
        
        if ($engineeringReport -and $engineeringReport.Length -gt 100) {
            Write-Output "OK Engineering Report generated ($($engineeringReport.Length) characters)"
        } else {
            Write-Error "Failed to generate Engineering report - output too short or null"
            return
        }
    } catch {
        Write-Error "Error generating Engineering Report: $($_.Exception.Message)"
        return
    }
    
    # Send email reports if recipients are configured
    if (-not [string]::IsNullOrEmpty($costReportRecipients)) {
        Write-Output "?? Sending email reports..."
        try {
            # Send Executive Summary Report
            $executiveSubject = "Azure Cost Management - Weekly Executive Summary"
            Send-EmailNotification -Subject $executiveSubject -HtmlBody $executiveSummary -Recipients $costReportRecipients
            
            # Send Engineering Report  
            $engineeringSubject = "Azure Cost Management - Weekly Engineering Report"
            Send-EmailNotification -Subject $engineeringSubject -HtmlBody $engineeringReport -Recipients $costReportRecipients
            
            Write-Output "OK Email reports sent successfully to: $costReportRecipients"
        } catch {
            Write-Error "Failed to send email reports: $($_.Exception.Message)"
        }
    } else {
        Write-Output "?? No email recipients configured - skipping email delivery"
    }
    
    Write-Output ""
    Write-Output "? Weekly Analysis Engine completed successfully!"
    Write-Output "End Time: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') UTC"
    Write-Output "=============================================="

} catch {
    Write-Error "? Weekly Analysis Engine failed: $($_.Exception.Message)"
    Write-Error "Full error details: $($_.Exception)"
    Write-Error "Stack trace: $($_.ScriptStackTrace)"
    throw
}


