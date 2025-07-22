# WeeklyAnalysisEngine-MVP.ps1
param(
    [string]$SubscriptionIds = ""  # Comma-separated list, will use automation variable if empty
)

# Ensures you do not inherit an AzContext in your runbook
Disable-AzContextAutosave -Scope Process

# Import required modules for Azure Automation
Import-Module Az.Accounts -Force
Import-Module Az.OperationalInsights -Force

# Add required assemblies for HTML encoding
Add-Type -AssemblyName System.Web

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
            $results = Invoke-AzOperationalInsightsQuery -WorkspaceId $WorkspaceId -Query $Query
            Write-Host " Successfully executed $QueryName - Retrieved $($results.Results.Count) records"
            $queryResults = $results.Results
            return $queryResults
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
                Write-Warning ($Query.Substring(0, [Math]::Min(200, $Query.Length)))

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
            Write-Output "Preparing to send email notification via Microsoft Graph REST API (attempt $($retryCount + 1) of $maxRetries)"

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
                Write-Output "  EmailFromAddress: $(if($fromAddress){'✓ Set'}else{'✗ Missing'})"
                Write-Output "  EmailClientId: $(if($clientId){'✓ Set'}else{'✗ Missing'})"
                Write-Output "  EmailTenantId: $(if($tenantId){'✓ Set'}else{'✗ Missing'})"
                Write-Output "  EmailClientSecret: $(if($clientSecret){'✓ Set'}else{'✗ Missing'})"
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

            Write-Output "Sending email to $($recipientList.Count) recipient(s)"

            # Ensure proper HTML content formatting and encoding
            Write-Output "Preparing HTML email content for Microsoft Graph API..."
            
            # Validate and sanitize HTML content
            if ($HtmlBody.Length -gt 1000000) {
                Write-Warning "HTML body is very large ($($HtmlBody.Length) characters). Truncating to prevent API limits."
                $HtmlBody = $HtmlBody.Substring(0, 1000000) + "<br><em>Content truncated due to size limits.</em>"
            }
            
            # Ensure HTML content has proper DOCTYPE and encoding for email clients
            if (-not $HtmlBody.StartsWith("<!DOCTYPE")) {
                Write-Output "Adding proper HTML document structure for email compatibility..."
                $HtmlBody = "<!DOCTYPE html>" + "`n" + $HtmlBody
            }
            
            # Force contentType to uppercase "HTML" as required by Microsoft Graph API
            $emailContentType = "HTML"
            Write-Output "Using contentType: '$emailContentType' for proper HTML rendering"

            $emailMessage = @{
                message = @{
                    subject = $Subject
                    body = @{
                        contentType = $emailContentType
                        content = $HtmlBody
                    }
                    toRecipients = $recipientList
                    importance = "normal"
                }
                saveToSentItems = $true
            }

            # Send email using Microsoft Graph with enhanced error handling
            $graphUri = "https://graph.microsoft.com/v1.0/users/$fromAddress/sendMail"
            $headers = @{
                "Authorization" = "Bearer $accessToken"
                "Content-Type" = "application/json; charset=utf-8"
                "Accept" = "application/json"
                "User-Agent" = "NIP-Azure-Cost-Analysis/1.0"
            }

            # Convert to JSON with proper encoding and depth for complex HTML structure
            $emailJson = ConvertTo-Json $emailMessage -Depth 15 -Compress
            Write-Output "Sending HTML email via Microsoft Graph API..."
            Write-Output "Email payload size: $($emailJson.Length) characters"
            Write-Output "HTML content type: $emailContentType"
            
            $response = Invoke-RestMethod -Uri $graphUri -Method Post -Headers $headers -Body $emailJson -TimeoutSec 60
            
            Write-Output " HTML email notification sent successfully to: $Recipients"
            Write-Output " Email sent with contentType: $emailContentType"
            Write-Output " HTML content size: $($HtmlBody.Length) characters"
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
            
            Write-Warning "Failed to send email notification (attempt $retryCount): $errorMessage"

            # Handle specific error types
            if ($errorMessage -like "*400*" -or $statusCode -eq 400) {
                Write-Warning "Bad Request (400) - This may indicate:"
                Write-Warning "  - Invalid email addresses"
                Write-Warning "  - Malformed request body"
                Write-Warning "  - HTML content formatting issues"
                Write-Warning "  - Missing required permissions"
                Write-Warning "  - Invalid authentication credentials"
                Write-Warning "  - HTML contentType not properly set"
                
                # Log additional details for HTML email debugging
                Write-Output "Email debugging information:"
                Write-Output "  Content Type Used: $emailContentType"
                Write-Output "  HTML Content Length: $($HtmlBody.Length) chars"
                Write-Output "  JSON Payload Length: $($emailJson.Length) chars"
                
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
                Write-Error "Failed to send email notification after $maxRetries attempts: $errorMessage"
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
        [Parameter(Mandatory=$true)]
        [string]$CostDataJson,
        [string]$PerformanceDataJson = "[]",
        [string]$RightsizingDataJson = "[]",
        [string]$DailyCostTrendsJson = "[]",
        [string]$ServiceCostAnalysisJson = "[]",
        [string]$BaselineDataJson = "[]",
        [string]$HistoricalDataJson = "[]",
        [string]$ResourceInventoryJson = "[]",
        [string]$CostAnomaliesJson = "[]",
        [string]$AnalysisType = "weekly"
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
3. SERVICE COST ANALYSIS & GROWTH: {2}
4. BASELINE COMPARISON DATA: {3}
5. HISTORICAL TRENDS (90 days): {4}
6. RESOURCE INVENTORY & EFFICIENCY: {5}
7. COST ANOMALIES DETECTED: {6}
8. PERFORMANCE METRICS (CPU, Memory, Disk, Network): {7}
9. VM RIGHTSIZING ANALYSIS: {8}

Focus on:
1. Cost Trends: Weekly spending patterns, anomalies, and growth analysis
2. Top Cost Drivers: Services/resources consuming the most budget with growth trends
3. AVD Analysis: Specific insights on Azure Virtual Desktop costs vs non-AVD
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

            $prompt = $prompt -f $CostDataJson, $DailyCostTrendsJson, $ServiceCostAnalysisJson, $BaselineDataJson, $HistoricalDataJson, $ResourceInventoryJson, $CostAnomaliesJson, $PerformanceDataJson, $RightsizingDataJson

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

function New-HtmlReport {
    param(
        [hashtable]$ReportData
    )
    
    # Extract data from the hashtable with null checks and safe defaults
    $totalCost = if ($ReportData.TotalCost -ne $null) { [double]$ReportData.TotalCost } else { 0 }
    $avdCost = if ($ReportData.AvdCost -ne $null) { [double]$ReportData.AvdCost } else { 0 }
    $nonAvdCost = if ($ReportData.NonAvdCost -ne $null) { [double]$ReportData.NonAvdCost } else { 0 }
    $subscriptionIds = if ($ReportData.SubscriptionIds -ne $null) { @($ReportData.SubscriptionIds) } else { @() }
    $rightsizingData = if ($ReportData.RightsizingData -ne $null) { @($ReportData.RightsizingData) } else { @() }
    $underutilizedVMs = if ($ReportData.UnderutilizedVMs -ne $null) { @($ReportData.UnderutilizedVMs) } else { @() }
    $overutilizedVMs = if ($ReportData.OverutilizedVMs -ne $null) { @($ReportData.OverutilizedVMs) } else { @() }
    $costVariance = if ($ReportData.CostVariance -ne $null) { [double]$ReportData.CostVariance } else { 0 }
    $costAnomalies = if ($ReportData.CostAnomalies -ne $null) { @($ReportData.CostAnomalies) } else { @() }
    $resourceInventory = if ($ReportData.ResourceInventory -ne $null) { @($ReportData.ResourceInventory) } else { @() }
    $costData = if ($ReportData.CostData -ne $null) { @($ReportData.CostData) } else { @() }
    $serviceCostAnalysis = if ($ReportData.ServiceCostAnalysis -ne $null) { @($ReportData.ServiceCostAnalysis) } else { @() }
    $aiAnalysisResults = if ($ReportData.AiAnalysisResults -ne $null) { $ReportData.AiAnalysisResults } else { @{} }
    $performanceData = if ($ReportData.PerformanceData -ne $null) { @($ReportData.PerformanceData) } else { @() }
    $historicalData = if ($ReportData.HistoricalData -ne $null) { @($ReportData.HistoricalData) } else { @() }
    $baselineData = if ($ReportData.BaselineData -ne $null) { @($ReportData.BaselineData) } else { @() }
    $dailyCostTrends = if ($ReportData.DailyCostTrends -ne $null) { @($ReportData.DailyCostTrends) } else { @() }
    $trendDirection = if ($ReportData.TrendDirection -ne $null) { $ReportData.TrendDirection } else { "Unknown" }
    $projectedWeeklyCost = if ($ReportData.ProjectedWeeklyCost -ne $null) { [double]$ReportData.ProjectedWeeklyCost } else { 0 }

    # Safe access to AI analysis results
    $aiSummary = if ($aiAnalysisResults.summary -ne $null) { $aiAnalysisResults.summary } else { @{} }
    $aiRecommendations = if ($aiAnalysisResults.recommendations -ne $null) { @($aiAnalysisResults.recommendations) } else { @() }
    $aiAnomalyAnalysis = if ($aiAnalysisResults.anomalyAnalysis -ne $null) { @($aiAnalysisResults.anomalyAnalysis) } else { @() }
    $aiResourceEfficiency = if ($aiAnalysisResults.resourceEfficiency -ne $null) { @($aiAnalysisResults.resourceEfficiency) } else { @() }
    
    # Safe calculation of potential savings
    $potentialSavings = if ($aiSummary.potentialSavings -ne $null) { [double]$aiSummary.potentialSavings } else { 0 }

    # Start building HTML
    $html = @"
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>NIP Group Azure Cost Analysis Report - $(Get-Date -Format 'MMMM dd, yyyy')</title>
    <style>
        /* NIP Group Professional Styling */
        * { margin: 0; padding: 0; box-sizing: border-box; }
        
        body {
            font-family: 'Segoe UI', -apple-system, BlinkMacSystemFont, 'Roboto', 'Oxygen', 'Ubuntu', 'Cantarell', 'Open Sans', 'Helvetica Neue', sans-serif;
            line-height: 1.6;
            color: #1e293b;
            background: linear-gradient(135deg, #0f172a 0%, #1e40af 25%, #2563eb 75%, #3b82f6 100%);
            min-height: 100vh;
            padding: 0;
            margin: 0;
        }
        
        .email-container {
            max-width: 1200px;
            margin: 0 auto;
            background: #ffffff;
            box-shadow: 0 25px 50px rgba(59, 130, 246, 0.15);
            border-radius: 0;
            overflow: hidden;
            border-top: 4px solid #2563eb;
        }
        
        /* NIP Group Header Styling */
        .header {
            background: linear-gradient(135deg, #0f172a 0%, #1e40af 50%, #2563eb 100%);
            color: white;
            padding: 40px;
            position: relative;
            overflow: hidden;
        }
        
        .header::before {
            content: '';
            position: absolute;
            top: 0;
            right: 0;
            width: 100%;
            height: 100%;
            background: url('data:image/svg+xml,<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 100"><defs><pattern id="nipPattern" width="60" height="60" patternUnits="userSpaceOnUse"><circle cx="30" cy="30" r="2" fill="rgba(255,255,255,0.1)"/><circle cx="15" cy="45" r="1.5" fill="rgba(59,130,246,0.2)"/><circle cx="45" cy="15" r="1" fill="rgba(37,99,235,0.15)"/></pattern></defs><rect width="100" height="100" fill="url(%23nipPattern)"/></svg>');
            opacity: 0.4;
        }
        
        .header-content {
            position: relative;
            z-index: 2;
        }
        
        .nip-logo {
            display: inline-flex;
            align-items: center;
            margin-bottom: 16px;
        }
        
        .nip-logo::before {
            content: '';
            display: inline-block;
            width: 40px;
            height: 40px;
            background: linear-gradient(135deg, #3b82f6 0%, #60a5fa 50%, #93c5fd 100%);
            border-radius: 50%;
            margin-right: 12px;
            position: relative;
        }
        
        .nip-logo::after {
            content: 'NIP';
            position: absolute;
            left: 0;
            top: 50%;
            transform: translateY(-50%);
            width: 40px;
            height: 40px;
            display: flex;
            align-items: center;
            justify-content: center;
            font-size: 12px;
            font-weight: 700;
            color: white;
            letter-spacing: 0.5px;
        }
        
        .header h1 {
            font-size: 2.5rem;
            font-weight: 700;
            margin-bottom: 12px;
            letter-spacing: -0.025em;
        }
        
        .header .subtitle {
            font-size: 1.125rem;
            font-weight: 400;
            opacity: 0.9;
            margin-bottom: 8px;
        }
        
        .header .tagline {
            font-size: 0.975rem;
            opacity: 0.8;
            font-weight: 300;
        }
        
        /* NIP Group Executive Summary */
        .executive-summary {
            background: linear-gradient(135deg, #f8fafc 0%, #e0f2fe 50%, #f0f9ff 100%);
            padding: 40px;
            border-bottom: 3px solid #2563eb;
            position: relative;
        }
        
        .executive-summary::before {
            content: '';
            position: absolute;
            top: 0;
            left: 0;
            right: 0;
            height: 2px;
            background: linear-gradient(90deg, #2563eb 0%, #3b82f6 50%, #60a5fa 100%);
        }
        
        .summary-grid {
            display: grid;
            grid-template-columns: repeat(auto-fit, minmax(280px, 1fr));
            gap: 24px;
            margin-top: 24px;
        }
        
        .summary-card {
            background: white;
            padding: 24px;
            border-radius: 16px;
            box-shadow: 0 4px 6px -1px rgba(37, 99, 235, 0.1), 0 2px 4px -1px rgba(59, 130, 246, 0.06);
            border: 1px solid #e0f2fe;
            border-left: 4px solid #2563eb;
            transition: transform 0.3s ease, box-shadow 0.3s ease;
        }
        
        .summary-card:hover {
            transform: translateY(-4px);
            box-shadow: 0 12px 25px -5px rgba(37, 99, 235, 0.15), 0 10px 10px -5px rgba(59, 130, 246, 0.1);
        }
        
        .summary-card.primary {
            background: linear-gradient(135deg, #2563eb 0%, #3b82f6 50%, #1d4ed8 100%);
            color: white;
            border-left-color: #1e40af;
        }
        
        .summary-card.success {
            background: linear-gradient(135deg, #059669 0%, #10b981 50%, #34d399 100%);
            color: white;
            border-left-color: #047857;
        }
        
        .summary-card.warning {
            background: linear-gradient(135deg, #d97706 0%, #f59e0b 50%, #fbbf24 100%);
            color: white;
            border-left-color: #b45309;
        }
        
        .summary-card.danger {
            background: linear-gradient(135deg, #dc2626 0%, #ef4444 50%, #f87171 100%);
            color: white;
            border-left-color: #b91c1c;
        }
        
        .metric-value {
            font-size: 2.25rem;
            font-weight: 800;
            line-height: 1;
            margin-bottom: 8px;
        }
        
        .metric-label {
            font-size: 0.875rem;
            font-weight: 500;
            opacity: 0.8;
            text-transform: uppercase;
            letter-spacing: 0.05em;
        }
        
        .metric-change {
            font-size: 0.75rem;
            margin-top: 4px;
            opacity: 0.9;
        }
        
        /* Content Sections */
        .content-section {
            padding: 32px 40px;
            border-bottom: 1px solid #e5e7eb;
        }
        
        .content-section:last-child {
            border-bottom: none;
        }
        
        .section-header {
            display: flex;
            align-items: center;
            margin-bottom: 24px;
        }
        
        .section-title {
            font-size: 1.5rem;
            font-weight: 700;
            color: #0f172a;
            margin-left: 12px;
        }
        
        .section-icon {
            font-size: 1.5rem;
            width: 48px;
            height: 48px;
            background: linear-gradient(135deg, #2563eb 0%, #3b82f6 100%);
            border-radius: 12px;
            display: flex;
            align-items: center;
            justify-content: center;
            color: white;
            box-shadow: 0 4px 6px -1px rgba(37, 99, 235, 0.3);
        }
        
        /* NIP Group Modern Tables */
        .data-table {
            width: 100%;
            border-collapse: separate;
            border-spacing: 0;
            background: white;
            border-radius: 12px;
            overflow: hidden;
            box-shadow: 0 1px 3px 0 rgba(37, 99, 235, 0.1), 0 1px 2px 0 rgba(59, 130, 246, 0.06);
            margin: 16px 0;
            border: 1px solid #e0f2fe;
        }
        
        .data-table th {
            background: linear-gradient(135deg, #0f172a 0%, #1e40af 50%, #2563eb 100%);
            color: white;
            padding: 16px 20px;
            text-align: left;
            font-weight: 600;
            font-size: 0.875rem;
            text-transform: uppercase;
            letter-spacing: 0.05em;
        }
        
        .data-table td {
            padding: 16px 20px;
            border-bottom: 1px solid #f3f4f6;
            font-size: 0.875rem;
        }
        
        .data-table tr:last-child td {
            border-bottom: none;
        }
        
        .data-table tr:hover {
            background: linear-gradient(135deg, #f0f9ff 0%, #e0f2fe 100%);
        }
        
        /* NIP Group Status Classes */
        .status-high { background: linear-gradient(135deg, #fef2f2 0%, #fee2e2 100%); border-left: 4px solid #ef4444; }
        .status-medium { background: linear-gradient(135deg, #fffbeb 0%, #fef3c7 100%); border-left: 4px solid #f59e0b; }
        .status-low { background: linear-gradient(135deg, #f0fdf4 0%, #dcfce7 100%); border-left: 4px solid #10b981; }
        .status-critical { background: linear-gradient(135deg, #fef2f2 0%, #fee2e2 100%); border-left: 4px solid #dc2626; }
        
        /* NIP Group Alert Cards */
        .alert-card {
            background: white;
            border-radius: 16px;
            padding: 20px;
            margin: 12px 0;
            border-left: 4px solid #2563eb;
            box-shadow: 0 1px 3px 0 rgba(37, 99, 235, 0.1);
            border: 1px solid #e0f2fe;
        }
        
        .alert-card.warning { 
            border-left-color: #f59e0b; 
            background: linear-gradient(135deg, #fffbeb 0%, #fef3c7 100%); 
            border-color: #fed7aa;
        }
        .alert-card.danger { 
            border-left-color: #ef4444; 
            background: linear-gradient(135deg, #fef2f2 0%, #fee2e2 100%); 
            border-color: #fecaca;
        }
        .alert-card.success { 
            border-left-color: #10b981; 
            background: linear-gradient(135deg, #f0fdf4 0%, #dcfce7 100%); 
            border-color: #bbf7d0;
        }
        
        .alert-title {
            font-weight: 600;
            margin-bottom: 8px;
            color: #0f172a;
        }
        
        .alert-content {
            color: #334155;
            font-size: 0.875rem;
            line-height: 1.5;
        }
        
        /* Grid Layouts */
        .kpi-grid {
            display: grid;
            grid-template-columns: repeat(auto-fit, minmax(200px, 1fr));
            gap: 16px;
            margin: 20px 0;
        }
        
        .kpi-card {
            background: white;
            padding: 20px;
            border-radius: 16px;
            text-align: center;
            box-shadow: 0 1px 3px 0 rgba(37, 99, 235, 0.1);
            border: 1px solid #e0f2fe;
            border-top: 3px solid #2563eb;
            transition: transform 0.2s ease, box-shadow 0.2s ease;
        }
        
        .kpi-card:hover {
            transform: translateY(-2px);
            box-shadow: 0 4px 6px -1px rgba(37, 99, 235, 0.15);
        }
        
        .kpi-value {
            font-size: 1.75rem;
            font-weight: 700;
            color: #0f172a;
            margin-bottom: 4px;
        }
        
        .kpi-label {
            font-size: 0.75rem;
            color: #475569;
            text-transform: uppercase;
            letter-spacing: 0.05em;
            font-weight: 500;
        }
        
        /* Trend Indicators */
        .trend-up { color: #ef4444; }
        .trend-down { color: #10b981; }
        .trend-stable { color: #6b7280; }
        
        /* NIP Group Footer */
        .report-footer {
            background: linear-gradient(135deg, #f8fafc 0%, #e0f2fe 100%);
            padding: 32px 40px;
            border-top: 2px solid #2563eb;
            text-align: center;
            position: relative;
        }
        
        .report-footer::before {
            content: '';
            position: absolute;
            top: 0;
            left: 0;
            right: 0;
            height: 2px;
            background: linear-gradient(90deg, #2563eb 0%, #3b82f6 50%, #60a5fa 100%);
        }
        
        .footer-content {
            font-size: 0.875rem;
            color: #475569;
            line-height: 1.5;
        }
        
        .footer-timestamp {
            font-weight: 600;
            color: #0f172a;
            margin-top: 8px;
        }
        
        .nip-footer-brand {
            margin-top: 16px;
            padding-top: 16px;
            border-top: 1px solid #cbd5e1;
            color: #2563eb;
            font-weight: 600;
            font-size: 0.875rem;
        }
        
        /* Responsive Design */
        @media (max-width: 768px) {
            .header, .content-section, .executive-summary, .report-footer {
                padding: 24px 20px;
            }
            
            .header h1 { font-size: 2rem; }
            .summary-grid { grid-template-columns: 1fr; }
            .kpi-grid { grid-template-columns: repeat(auto-fit, minmax(150px, 1fr)); }
        }
        
        /* Print Styles */
        @media print {
            body { background: white; }
            .email-container { box-shadow: none; }
            .summary-card:hover, .data-table tr:hover { transform: none; background-color: transparent; }
        }
    </style>
</head>
<body>
    <div class="email-container">
        <div class="header">
            <div class="header-content">
                <div class="nip-logo"></div>
                <h1> NIP Group Azure Cost Intelligence</h1>
                <div class="subtitle">Weekly Cost Analysis & Optimization Insights</div>
                <div class="tagline">$(Get-Date -Format 'MMMM dd, yyyy') • AI-Powered Analysis • Performance Metrics • Rightsizing Recommendations</div>
            </div>
        </div>

        <div class="executive-summary">
            <h2 style="font-size: 1.75rem; font-weight: 700; color: #0f172a; margin-bottom: 8px;">Executive Dashboard</h2>
            <p style="color: #475569; margin-bottom: 24px;">Key metrics and cost insights across your Azure environment</p>
            
            <div class="summary-grid">
                <div class="summary-card primary">
                    <div class="metric-value">$($totalCost.ToString('C2'))</div>
                    <div class="metric-label">Total Weekly Cost</div>
                    <div class="metric-change">$(if($trendDirection -eq 'up'){' Trending Up'}elseif($trendDirection -eq 'down'){' Trending Down'}else{' Stable'})</div>
                </div>
                <div class="summary-card $(if($potentialSavings -gt 1000){'success'}elseif($potentialSavings -gt 500){'warning'}else{'primary'})">
                    <div class="metric-value">$(if($potentialSavings -gt 0){$potentialSavings.ToString('C2')}else{'TBD'})</div>
                    <div class="metric-label">Potential Savings</div>
                    <div class="metric-change">AI-Identified Opportunities</div>
                </div>
                <div class="summary-card $(if($costVariance -gt 20){'danger'}elseif($costVariance -gt 10){'warning'}else{'success'})">
                    <div class="metric-value">$($costVariance.ToString('F1'))%</div>
                    <div class="metric-label">Baseline Variance</div>
                    <div class="metric-change">$(if($costVariance -gt 0){'Above'}else{'Below'}) Expected</div>
                </div>
                <div class="summary-card $(if($costAnomalies.Count -gt 3){'warning'}elseif($costAnomalies.Count -gt 0){'primary'}else{'success'})">
                    <div class="metric-value">$($costAnomalies.Count)</div>
                    <div class="metric-label">Anomalies Detected</div>
                    <div class="metric-change">Cost Pattern Analysis</div>
                </div>
            </div>
            
            <div class="kpi-grid" style="margin-top: 32px;">
                <div class="kpi-card">
                    <div class="kpi-value">$($subscriptionIds.Count)</div>
                    <div class="kpi-label">Subscriptions</div>
                </div>
                <div class="kpi-card">
                    <div class="kpi-value">$($rightsizingData.Count)</div>
                    <div class="kpi-label">VMs Analyzed</div>
                </div>
                <div class="kpi-card">
                    <div class="kpi-value">$($underutilizedVMs.Count)</div>
                    <div class="kpi-label">Underutilized VMs</div>
                </div>
                <div class="kpi-card">
                    <div class="kpi-value">$(if($overutilizedVMs.Count -gt 0){$overutilizedVMs.Count}else{0})</div>
                    <div class="kpi-label">Overutilized VMs</div>
                </div>
                <div class="kpi-card">
                    <div class="kpi-value">$($avdCost.ToString('C2'))</div>
                    <div class="kpi-label">AVD Resources</div>
                </div>
                <div class="kpi-card">
                    <div class="kpi-value">$(if($totalCost -gt 0){($avdCost / $totalCost * 100).ToString('F1')}else{0})%</div>
                    <div class="kpi-label">AVD Cost Ratio</div>
                </div>
            </div>
        </div>
"@

    # Add anomalies section
    $html += @"
        <div class="content-section">
            <div class="section-header">
                <div class="section-icon">⚠️</div>
                <h2 class="section-title">Cost Anomalies & Alerts</h2>
            </div>
"@
    
    if ($costAnomalies.Count -gt 0) {
        $html += @"
            <table class="data-table">
                <thead>
                    <tr>
                        <th>Date</th>
                        <th>Service</th>
                        <th>Daily Cost</th>
                        <th>Change %</th>
                        <th>Anomaly Type</th>
                        <th>Impact</th>
                    </tr>
                </thead>
                <tbody>
"@
        foreach ($anomaly in ($costAnomalies | Select-Object -First 5)) {
            $anomalyClass = if ($anomaly.AnomalyType -like "*Spike*") { "status-high" } else { "status-medium" }
            $costDate = if ($anomaly.CostDate -ne $null) { $anomaly.CostDate } else { "N/A" }
            $serviceName = if ($anomaly.ServiceName_s -ne $null) { $anomaly.ServiceName_s } else { "Unknown" }
            $dailyCost = if ($anomaly.DailyCost -ne $null) { [double]$anomaly.DailyCost } else { 0 }
            $dayOverDayChange = if ($anomaly.DayOverDayChange -ne $null) { [double]$anomaly.DayOverDayChange } else { 0 }
            $anomalyType = if ($anomaly.AnomalyType -ne $null) { $anomaly.AnomalyType } else { "Unknown" }
            $impactIcon = if ($dailyCost -gt 500) { "High Impact" } elseif ($dailyCost -gt 100) { "Medium Impact" } else { "Low Impact" }
            
            $html += @"
                    <tr class="$anomalyClass">
                        <td><strong>$costDate</strong></td>
                        <td>$serviceName</td>
                        <td><strong>$($dailyCost.ToString('C2'))</strong></td>
                        <td class="$(if($dayOverDayChange -gt 0){'trend-up'}else{'trend-down'})"><strong>$($dayOverDayChange.ToString('F1'))%</strong></td>
                        <td>$anomalyType</td>
                        <td>$impactIcon</td>
                    </tr>
"@
        }
        $html += @"
                </tbody>
            </table>
"@
    } else {
        $html += @"
            <div class="alert-card success">
                <div class="alert-title"> No Critical Anomalies Detected</div>
                <div class="alert-content">Cost patterns are within expected ranges for the analyzed period.</div>
            </div>
"@
    }
    
    $html += "</div>"

    # Add VM rightsizing section
    $html += @"
        <div class="content-section">
            <div class="section-header">
                <div class="section-icon">💻</div>
                <h2 class="section-title">VM Rightsizing Opportunities</h2>
            </div>
"@
    
    if ($rightsizingData.Count -gt 0) {
        $html += @"
            <table class="data-table">
                <thead>
                    <tr>
                        <th>VM Name</th>
                        <th>CPU Utilization</th>
                        <th>Memory Utilization</th>
                        <th>Utilization Score</th>
                        <th>Recommendation</th>
                        <th>Priority</th>
                    </tr>
                </thead>
                <tbody>
"@
        foreach ($vm in ($rightsizingData | Sort-Object UtilizationScore | Select-Object -First 10)) {
            $utilizationScore = if ($vm.UtilizationScore -ne $null) { [double]$vm.UtilizationScore } else { 0 }
            $utilizationClass = switch ($vm.CPUUtilizationCategory) {
                "Severely Underutilized" { "status-critical" }
                "Underutilized" { "status-high" }
                "Over Utilized" { "status-high" }
                default { "status-low" }
            }
            $computer = if ($vm.Computer -ne $null) { $vm.Computer } else { "Unknown" }
            $avgCPU = if ($vm.AvgCPU -ne $null) { [double]$vm.AvgCPU } else { 0 }
            $avgMemory = if ($vm.AvgMemory -ne $null) { [double]$vm.AvgMemory } else { 0 }
            $recommendation = if ($vm.RightsizingRecommendation -ne $null) { $vm.RightsizingRecommendation } else { "Monitor performance" }
            $priority = if ($utilizationScore -lt 20) { "High Priority" } elseif ($utilizationScore -lt 40) { "Medium Priority" } else { "Low Priority" }
            
            $html += @"
                    <tr class="$utilizationClass">
                        <td><strong>$computer</strong></td>
                        <td><span style="font-weight: 600;">$($avgCPU.ToString('F1'))%</span></td>
                        <td><span style="font-weight: 600;">$($avgMemory.ToString('F1'))%</span></td>
                        <td><span style="font-weight: 600;">$($utilizationScore.ToString('F1'))</span></td>
                        <td>$recommendation</td>
                        <td>$priority</td>
                    </tr>
"@
        }
        $html += @"
                </tbody>
            </table>
"@
    } else {
        $html += @"
            <div class="alert-card warning">
                <div class="alert-title"> Performance Data Unavailable</div>
                <div class="alert-content">No performance data available for VM rightsizing analysis. Ensure VMs are connected to the Data Collection Rule and performance counters are being collected.</div>
            </div>
"@
    }
    
    $html += "</div>"

    # Add top cost services section
    $html += @"
        <div class="content-section">
            <div class="section-header">
                <div class="section-icon">💰</div>
                <h2 class="section-title">Top Cost Services</h2>
            </div>
"@
    
    if ($costData.Count -gt 0) {
        $html += @"
            <table class="data-table">
                <thead>
                    <tr>
                        <th>Service Name</th>
                        <th>Weekly Cost</th>
                        <th>Daily Average</th>
                        <th>Resource Count</th>
                        <th>AVD Related</th>
                        <th>Cost Category</th>
                    </tr>
                </thead>
                <tbody>
"@
        foreach ($service in ($costData | Select-Object -First 10)) {
            $totalCostValue = if ($service.TotalCost -ne $null) { [double]$service.TotalCost } else { 0 }
            $avgDailyCost = if ($service.AvgDailyCost -ne $null) { [double]$service.AvgDailyCost } else { 0 }
            $costClass = if ($totalCostValue -gt 500) { "status-critical" } elseif ($totalCostValue -gt 200) { "status-high" } elseif ($totalCostValue -gt 50) { "status-medium" } else { "status-low" }
            $serviceName = if ($service.ServiceName_s -ne $null) { $service.ServiceName_s } else { "Unknown" }
            $resourceCount = if ($service.ResourceCount -ne $null) { $service.ResourceCount } else { 0 }
            $isAVD = if ($service.IsAVD -eq $true) { 'Yes' } else { 'No' }
            $costCategory = if ($totalCostValue -gt 500) { "Critical" } elseif ($totalCostValue -gt 200) { "High" } elseif ($totalCostValue -gt 50) { "Medium" } else { "Low" }
            
            $html += @"
                    <tr class="$costClass">
                        <td><strong>$serviceName</strong></td>
                        <td><strong>$($totalCostValue.ToString('C2'))</strong></td>
                        <td>$($avgDailyCost.ToString('C2'))</td>
                        <td>$resourceCount</td>
                        <td>$isAVD</td>
                        <td>$costCategory</td>
                    </tr>
"@
        }
        $html += @"
                </tbody>
            </table>
"@
    } else {
        $html += @"
            <div class="alert-card warning">
                <div class="alert-title"> No Cost Data Available</div>
                <div class="alert-content">No current cost data found for the analysis period. Please check data collection processes.</div>
            </div>
"@
    }
    
    $html += "</div>"

    # Add recommendations section
    $html += @"
        <div class="content-section">
            <div class="section-header">
                <div class="section-icon">🎯</div>
                <h2 class="section-title">Priority Recommendations</h2>
            </div>
"@
    
    if ($aiRecommendations.Count -gt 0) {
        foreach ($rec in $aiRecommendations) {
            $priority = if ($rec.priority -ne $null) { $rec.priority } else { "medium" }
            $priorityIcon = switch ($priority) {
                "high" { "HIGH" }
                "medium" { "MED" }
                "low" { "LOW" }
                default { "INFO" }
            }
            $priorityClass = switch ($priority) {
                "high" { "danger" }
                "medium" { "warning" }
                "low" { "success" }
                default { "" }
            }
            $action = if ($rec.action -ne $null) { $rec.action } else { "No action specified" }
            $estimatedSavings = if ($rec.estimatedSavings -ne $null) { [double]$rec.estimatedSavings } else { 0 }
            $impact = if ($rec.impact -ne $null) { $rec.impact } else { "Review and assess" }
            
            $html += @"
            <div class="alert-card $priorityClass">
                <div class="alert-title">$priorityIcon $action</div>
                <div class="alert-content">
                    $impact
"@
            if ($estimatedSavings -gt 0) {
                $html += @"
                    <br><strong>💵 Estimated Potential Savings:</strong> $($estimatedSavings.ToString('C2'))
"@
            }
            $html += @"
                </div>
            </div>
"@
        }
    } else {
        # Fallback recommendations based on available data
        $downsizingCandidates = if ($rightsizingData.Count -gt 0) { 
            @($rightsizingData | Where-Object { $_.RightsizingRecommendation -ne $null -and $_.RightsizingRecommendation -like "*downsizing*" })
        } else { @() }
        
        $html += @"
            <div class="alert-card danger">
                <div class="alert-title">🔧 VM Rightsizing Priority</div>
                <div class="alert-content">Review $($downsizingCandidates.Count) virtual machines identified for potential downsizing. Focus on severely underutilized resources first.</div>
            </div>
            <div class="alert-card warning">
                <div class="alert-title">💰 Cost Optimization Focus</div>
                <div class="alert-content">Concentrate optimization efforts on the highest cost services and resources. Consider reserved instances for consistent workloads.</div>
            </div>
            <div class="alert-card">
                <div class="alert-title"> Enhanced Monitoring</div>
                <div class="alert-content">Implement comprehensive performance monitoring to enable detailed rightsizing analysis and cost optimization insights.</div>
            </div>
"@
    }
    
    $html += "</div>"

    # Add service cost growth analysis section
    $html += @"
        <div class="content-section">
            <div class="section-header">
                <div class="section-icon"></div>
                <h2 class="section-title">Service Cost Growth Analysis</h2>
            </div>
"@
    
    if ($serviceCostAnalysis.Count -gt 0) {
        $html += @"
            <table class="data-table">
                <thead>
                    <tr>
                        <th>Service</th>
                        <th>Current Week</th>
                        <th>Previous Week</th>
                        <th>Growth %</th>
                        <th>Absolute Change</th>
                        <th>Trend</th>
                    </tr>
                </thead>
                <tbody>
"@
        $validServices = $serviceCostAnalysis | Where-Object { 
            $_.CurrentWeek -ne $null -and ([double]$_.CurrentWeek) -gt 0 
        } | Sort-Object { if ($_.CurrentWeek -ne $null) { [double]$_.CurrentWeek } else { 0 } } -Descending | Select-Object -First 10
        
        foreach ($service in $validServices) {
            $currentWeek = if ($service.CurrentWeek -ne $null) { [double]$service.CurrentWeek } else { 0 }
            $previousWeek = if ($service.PreviousWeek -ne $null) { [double]$service.PreviousWeek } else { 0 }
            $weeklyGrowth = if ($service.WeeklyGrowth -ne $null) { [double]$service.WeeklyGrowth } else { 0 }
            $absoluteChange = if ($service.AbsoluteChange -ne $null) { [double]$service.AbsoluteChange } else { ($currentWeek - $previousWeek) }
            $serviceName = if ($service.ServiceName_s -ne $null) { $service.ServiceName_s } else { "Unknown" }
            
            $growthClass = if ($weeklyGrowth -gt 20) { "status-critical" } elseif ($weeklyGrowth -gt 10) { "status-high" } elseif ($weeklyGrowth -gt 0) { "status-medium" } else { "status-low" }
            $trendIcon = if ($weeklyGrowth -gt 20) { " Significant Increase" } elseif ($weeklyGrowth -gt 10) { " Notable Increase" } elseif ($weeklyGrowth -gt 0) { "� Minor Increase" } elseif ($weeklyGrowth -lt -10) { " Decrease" } else { " Stable" }
            $growthDisplay = if ($weeklyGrowth -gt 0) { "+$($weeklyGrowth.ToString('F1'))%" } else { "$($weeklyGrowth.ToString('F1'))%" }
            $changeDisplay = if ($absoluteChange -gt 0) { "+$($absoluteChange.ToString('C2'))" } else { "$($absoluteChange.ToString('C2'))" }
            
            $html += @"
                    <tr class="$growthClass">
                        <td><strong>$serviceName</strong></td>
                        <td><strong>$($currentWeek.ToString('C2'))</strong></td>
                        <td>$($previousWeek.ToString('C2'))</td>
                        <td class="$(if($weeklyGrowth -gt 0){'trend-up'}else{'trend-down'})"><strong>$growthDisplay</strong></td>
                        <td class="$(if($absoluteChange -gt 0){'trend-up'}else{'trend-down'})">$changeDisplay</td>
                        <td>$trendIcon</td>
                    </tr>
"@
        }
        $html += @"
                </tbody>
            </table>
"@
    } else {
        $html += @"
            <div class="alert-card warning">
                <div class="alert-title"> No Growth Data Available</div>
                <div class="alert-content">Service growth comparison data is not available. This may indicate insufficient historical data for week-over-week analysis.</div>
            </div>
"@
    }
    
    $html += "</div>"

    # Add historical trends section
    $html += @"
        <div class="content-section">
            <div class="section-header">
                <div class="section-icon">🕒</div>
                <h2 class="section-title">Historical Cost Trends</h2>
            </div>
"@
    
    if ($historicalData.Count -gt 0) {
        $html += @"
            <table class="data-table">
                <thead>
                    <tr>
                        <th>Month</th>
                        <th>Total Spend</th>
                        <th>Daily Average</th>
                        <th>Min Daily</th>
                        <th>Max Daily</th>
                        <th>Trend vs Average</th>
                    </tr>
                </thead>
                <tbody>
"@
        $avgMonthlySpend = if ($historicalData.Count -gt 0) { 
            $validSpends = $historicalData | Where-Object { $_.MonthlySpend -ne $null } | ForEach-Object { [double]$_.MonthlySpend }
            if ($validSpends) { ($validSpends | Measure-Object -Average).Average } else { 0 }
        } else { 0 }
        
        foreach ($month in ($historicalData | Sort-Object BillingMonth -Descending | Select-Object -First 6)) {
            $billingMonth = if ($month.BillingMonth -ne $null) { $month.BillingMonth } else { "Unknown" }
            $monthlySpend = if ($month.MonthlySpend -ne $null) { [double]$month.MonthlySpend } else { 0 }
            $avgDailyCost = if ($month.AvgDailyCost -ne $null) { [double]$month.AvgDailyCost } else { 0 }
            $minCost = if ($month.MinCost -ne $null) { [double]$month.MinCost } else { 0 }
            $maxCost = if ($month.MaxCost -ne $null) { [double]$month.MaxCost } else { 0 }
            $trendClass = if ($monthlySpend -gt $avgMonthlySpend * 1.1) { "status-high" } elseif ($monthlySpend -lt $avgMonthlySpend * 0.9) { "status-low" } else { "status-medium" }
            $trendLabel = if ($monthlySpend -gt $avgMonthlySpend * 1.1) { ' Above Average' } elseif ($monthlySpend -lt $avgMonthlySpend * 0.9) { ' Below Average' } else { ' Within Range' }
            
            $html += @"
                    <tr class="$trendClass">
                        <td><strong>$billingMonth</strong></td>
                        <td><strong>$($monthlySpend.ToString('C2'))</strong></td>
                        <td>$($avgDailyCost.ToString('C2'))</td>
                        <td>$($minCost.ToString('C2'))</td>
                        <td>$($maxCost.ToString('C2'))</td>
                        <td>$trendLabel</td>
                    </tr>
"@
        }
        $html += @"
                </tbody>
            </table>
"@
    } else {
        $html += @"
            <div class="alert-card warning">
                <div class="alert-title"> Limited Historical Data</div>
                <div class="alert-content">Historical cost trend data is not available. Historical analysis requires data from multiple billing periods.</div>
            </div>
"@
    }
    
    $html += "</div>"

    # Add baseline comparison section
    $html += @"
        <div class="content-section">
            <div class="section-header">
                <div class="section-icon"></div>
                <h2 class="section-title">Baseline Comparison Analysis</h2>
            </div>
"@
    
    if ($baselineData.Count -gt 0) {
        $avgBaselineValues = $baselineData | Where-Object { $_.AverageMonthlySpend -ne $null } | ForEach-Object { [double]$_.AverageMonthlySpend }
        $avgBaseline = if ($avgBaselineValues) { ($avgBaselineValues | Measure-Object -Average).Average } else { 0 }
        $projectedWeeklyCalc = if ($avgBaseline -gt 0) { $avgBaseline / 4.33 } else { 0 }
        $varianceCalc = if ($projectedWeeklyCalc -gt 0) { (($totalCost - $projectedWeeklyCalc) / $projectedWeeklyCalc) * 100 } else { 0 }
        $varianceClass = if ([math]::Abs($varianceCalc) -gt 20) { "danger" } elseif ([math]::Abs($varianceCalc) -gt 10) { "warning" } else { "success" }
        
        $html += @"
            <div class="kpi-grid">
                <div class="kpi-card">
                    <div class="kpi-value $(if($varianceCalc -gt 0){'trend-up'}else{'trend-down'})">$($varianceCalc.ToString('F1'))%</div>
                    <div class="kpi-label">Variance from Baseline</div>
                </div>
                <div class="kpi-card">
                    <div class="kpi-value">$($projectedWeeklyCalc.ToString('C2'))</div>
                    <div class="kpi-label">Expected Weekly Cost</div>
                </div>
                <div class="kpi-card">
                    <div class="kpi-value">$($avgBaseline.ToString('C2'))</div>
                    <div class="kpi-label">Monthly Baseline</div>
                </div>
                <div class="kpi-card">
                    <div class="kpi-value">$trendDirection</div>
                    <div class="kpi-label">Trend Direction</div>
                </div>
            </div>
            
            <div class="alert-card $varianceClass">
                <div class="alert-title">Baseline Analysis</div>
                <div class="alert-content">
                    Current weekly spending is <strong>$(if($varianceCalc -gt 0){'above'}else{'below'})</strong> the projected baseline by <strong>$([math]::Abs($varianceCalc).ToString('F1'))%</strong>.
                    $(if([math]::Abs($varianceCalc) -gt 20){'This represents a significant deviation that requires immediate attention.'}elseif([math]::Abs($varianceCalc) -gt 10){'This variance should be monitored closely.'}else{'Spending is within acceptable variance range.'})
                </div>
            </div>
"@
    } else {
        $html += @"
            <div class="alert-card warning">
                <div class="alert-title"> No Baseline Data Available</div>
                <div class="alert-content">Baseline comparison requires historical data collection over multiple periods. Continue collecting data to establish meaningful baselines.</div>
            </div>
"@
    }
    
    $html += "</div>"

    # Add resource inventory insights section
    $html += @"
        <div class="content-section">
            <div class="section-header">
                <div class="section-icon">🏗️</div>
                <h2 class="section-title">Resource Inventory & Efficiency Analysis</h2>
            </div>
"@
    
    if ($resourceInventory.Count -gt 0) {
        # Get top resources by cost efficiency with null checks
        $validResources = $resourceInventory | Where-Object { $_.TotalCost -ne $null -and ([double]$_.TotalCost) -gt 0 }
        $topResources = $validResources | Sort-Object { if ($_.TotalCost -ne $null) { [double]$_.TotalCost } else { 0 } } -Descending | Select-Object -First 8
        
        if ($topResources.Count -gt 0) {
            $html += @"
            <h3 style="color: #1f2937; margin-bottom: 16px; font-size: 1.125rem;">🔥 Highest Cost Resources</h3>
            <table class="data-table">
                <thead>
                    <tr>
                        <th>Resource Name</th>
                        <th>Resource Type</th>
                        <th>Service</th>
                        <th>Location</th>
                        <th>Weekly Cost</th>
                        <th>Daily Average</th>
                        <th>Days Active</th>
                        <th>Cost Efficiency</th>
                    </tr>
                </thead>
                <tbody>
"@
            foreach ($resource in $topResources) {
                $totalCostValue = if ($resource.TotalCost -ne $null) { [double]$resource.TotalCost } else { 0 }
                $avgDailyCost = if ($resource.AvgDailyCost -ne $null) { [double]$resource.AvgDailyCost } else { 0 }
                $daysWithCost = if ($resource.DaysWithCost -ne $null) { $resource.DaysWithCost } else { 0 }
                $costClass = if ($totalCostValue -gt 200) { "status-critical" } elseif ($totalCostValue -gt 100) { "status-high" } elseif ($totalCostValue -gt 50) { "status-medium" } else { "status-low" }
                $resourceName = if ($resource.ResourceName_s -ne $null) { $resource.ResourceName_s } else { "Unknown" }
                $resourceType = if ($resource.ResourceType -ne $null) { $resource.ResourceType } else { "Unknown" }
                $serviceName = if ($resource.ServiceName_s -ne $null) { $resource.ServiceName_s } else { "Unknown" }
                $location = if ($resource.Location_s -ne $null) { $resource.Location_s } else { "Unknown" }
                $efficiency = if ($daysWithCost -gt 0) { 
                    $dailyEfficiency = $totalCostValue / $daysWithCost
                    if ($dailyEfficiency -gt 50) { " High Cost" } elseif ($dailyEfficiency -gt 20) { " Moderate" } else { " Efficient" }
                } else { "Unknown" }
                
                $html += @"
                    <tr class="$costClass">
                        <td><strong>$resourceName</strong></td>
                        <td>$resourceType</td>
                        <td>$serviceName</td>
                        <td>$location</td>
                        <td><strong>$($totalCostValue.ToString('C2'))</strong></td>
                        <td>$($avgDailyCost.ToString('C2'))</td>
                        <td>$daysWithCost</td>
                        <td>$efficiency</td>
                    </tr>
"@
            }
            $html += @"
                </tbody>
            </table>
"@
        } else {
            $html += @"
            <div class="alert-card success">
                <div class="alert-title"> No High-Cost Resources Identified</div>
                <div class="alert-content">All resources are operating within cost-efficient ranges based on current analysis.</div>
            </div>
"@
        }
    } else {
        $html += @"
            <div class="alert-card warning">
                <div class="alert-title"> No Resource Inventory Data</div>
                <div class="alert-content">Resource inventory analysis requires cost data collection. Ensure data collection is running properly.</div>
            </div>
"@
    }
    
    $html += "</div>"

    # Enhanced AI analysis sections
    if ($aiAnomalyAnalysis.Count -gt 0) {
        $html += @"
        <div class="content-section">
            <div class="section-header">
                <div class="section-icon">🔍</div>
                <h2 class="section-title">AI-Powered Anomaly Analysis</h2>
            </div>
"@
        foreach ($anomaly in ($aiAnomalyAnalysis | Select-Object -First 5)) {
            $anomalyClass = if ($anomaly.type -eq "spike") { "danger" } else { "warning" }
            $date = if ($anomaly.date -ne $null) { $anomaly.date } else { "Unknown" }
            $service = if ($anomaly.service -ne $null) { $anomaly.service } else { "Unknown" }
            $impact = if ($anomaly.impact -ne $null) { [double]$anomaly.impact } else { 0 }
            $type = if ($anomaly.type -ne $null) { $anomaly.type } else { "unknown" }
            $rootCause = if ($anomaly.rootCause -ne $null) { $anomaly.rootCause } else { "Analysis pending" }
            $recommendation = if ($anomaly.recommendation -ne $null) { $anomaly.recommendation } else { "No recommendation available" }
            
            $html += @"
            <div class="alert-card $anomalyClass">
                <div class="alert-title">📅 $date - $service</div>
                <div class="alert-content">
                    <strong>Impact:</strong> $($impact.ToString('C2')) ($type)<br>
                    <strong>Root Cause:</strong> $rootCause<br>
                    <strong>Recommendation:</strong> $recommendation
                </div>
            </div>
"@
        }
        $html += "</div>"
    }

    if ($aiResourceEfficiency.Count -gt 0) {
        $html += @"
        <div class="content-section">
            <div class="section-header">
                <div class="section-icon">⚡</div>
                <h2 class="section-title">AI Resource Efficiency Analysis</h2>
            </div>
            <table class="data-table">
                <thead>
                    <tr>
                        <th>Resource</th>
                        <th>Cost Efficiency Score</th>
                        <th>Utilization Score</th>
                        <th>Performance Rating</th>
                        <th>AI Recommendation</th>
                    </tr>
                </thead>
                <tbody>
"@
        foreach ($resource in ($aiResourceEfficiency | Select-Object -First 5)) {
            $utilizationScore = if ($resource.utilizationScore -ne $null) { [double]$resource.utilizationScore } else { 0 }
            $efficiencyClass = if ($utilizationScore -lt 30) { "status-high" } elseif ($utilizationScore -gt 80) { "status-high" } else { "status-low" }
            $resourceName = if ($resource.resource -ne $null) { $resource.resource } else { "Unknown" }
            $costEfficiency = if ($resource.costEfficiency -ne $null) { [double]$resource.costEfficiency } else { 0 }
            $recommendation = if ($resource.recommendation -ne $null) { $resource.recommendation } else { "No recommendation" }
            $performanceRating = if ($utilizationScore -lt 30) { " Underutilized" } elseif ($utilizationScore -gt 80) { " Overutilized" } else { " Optimal" }
            
            $html += @"
                    <tr class="$efficiencyClass">
                        <td><strong>$resourceName</strong></td>
                        <td>$($costEfficiency.ToString('F2'))</td>
                        <td><strong>$($utilizationScore.ToString('F1'))%</strong></td>
                        <td>$performanceRating</td>
                        <td>$recommendation</td>
                    </tr>
"@
        }
        $html += @"
                </tbody>
            </table>
        </div>
"@
    }

    # Add raw AI analysis section if available (with better formatting)
    if ($aiAnalysisResults.rawAnalysisText -ne $null -and $aiAnalysisResults.rawAnalysisText.Length -gt 0) {
        $html += @"
        <div class="content-section">
            <div class="section-header">
                <div class="section-icon">🤖</div>
                <h2 class="section-title">Detailed AI Analysis</h2>
            </div>
            <div class="alert-card">
                <div class="alert-title">AI Analysis Output</div>
                <div class="alert-content" style="font-family: 'Courier New', monospace; white-space: pre-wrap; font-size: 0.875rem; line-height: 1.4; background: #f8fafc; padding: 16px; border-radius: 8px; margin-top: 12px;">
"@
        # Escape HTML characters and limit length
        $rawText = if ($aiAnalysisResults.rawAnalysisText.Length -gt 5000) { 
            $aiAnalysisResults.rawAnalysisText.Substring(0, 5000) + "`n`n[Content truncated - see full analysis in logs]"
        } else { 
            $aiAnalysisResults.rawAnalysisText 
        }
        $escapedText = [System.Web.HttpUtility]::HtmlEncode($rawText)
        $html += $escapedText
        $html += @"
                </div>
                <p style="margin-top: 12px; font-style: italic; color: #6b7280;">Note: Raw AI analysis output due to JSON parsing issues. Structured insights are displayed in sections above.</p>
            </div>
        </div>
"@
    }

    # Add comprehensive data quality and footer section
    $html += @"
        <div class="report-footer">
            <div class="footer-content">
                <h3 style="color: #0f172a; margin-bottom: 16px; font-size: 1.25rem;"> Data Quality & Coverage Summary</h3>
                
                <div class="kpi-grid" style="margin-bottom: 24px;">
                    <div class="kpi-card">
                        <div class="kpi-value">$($subscriptionIds.Count)</div>
                        <div class="kpi-label">Subscriptions Analyzed</div>
                    </div>
                    <div class="kpi-card">
                        <div class="kpi-value">$($costData.Count)</div>
                        <div class="kpi-label">Cost Services</div>
                    </div>
                    <div class="kpi-card">
                        <div class="kpi-value">$($rightsizingData.Count)</div>
                        <div class="kpi-label">VMs Monitored</div>
                    </div>
                    <div class="kpi-card">
                        <div class="kpi-value">$($performanceData.Count)</div>
                        <div class="kpi-label">Performance Metrics</div>
                    </div>
                    <div class="kpi-card">
                        <div class="kpi-value">$($dailyCostTrends.Count)</div>
                        <div class="kpi-label">Daily Records</div>
                    </div>
                    <div class="kpi-card">
                        <div class="kpi-value">$($serviceCostAnalysis.Count)</div>
                        <div class="kpi-label">Growth Analysis</div>
                    </div>
                </div>
                
                <div style="text-align: center; border-top: 1px solid #cbd5e1; padding-top: 20px;">
                    <p><strong>📅 Analysis Coverage:</strong> Weekly costs (7 days) • Daily trends (30 days) • Historical data (90 days)</p>
                    <p><strong>🤖 AI Analysis Status:</strong> $(if($aiSummary.costTrend -ne $null -and $aiSummary.costTrend -ne 'analysis_unavailable'){' Comprehensive AI analysis completed'}else{' Limited AI analysis available - check API connectivity'})</p>
                    <div class="footer-timestamp">
                         NIP Group Azure Cost Intelligence Report • Generated $(Get-Date -Format 'MMMM dd, yyyy \a\t HH:mm:ss') UTC
                    </div>
                    <div class="nip-footer-brand">
                        Powered by NIP Group Technology Solutions
                    </div>
                    <p style="margin-top: 12px; font-size: 0.75rem; color: #64748b;">
                        Azure Cost Management API • Claude AI Analysis • Log Analytics Workspace
                    </p>
                </div>
            </div>
        </div>
    </div>
</body>
</html>
"@

    return $html
}

# Main execution
try {
    Write-Output "Starting weekly cost analysis for $(Get-Date -Format 'yyyy-MM-dd')"

    # Connect to Azure with enhanced retry logic and environment detection
    Connect-AzureWithContext | Out-Null

    # Get target subscriptions from automation variable or parameter with auto-discovery fallback
    try {
        if ([string]::IsNullOrWhiteSpace($SubscriptionIds)) {
            $targetSubscriptions = Get-ConfigurationVariable -Name "TARGET_SUBSCRIPTION_IDS"
            if (-not $targetSubscriptions) {
                throw "TARGET_SUBSCRIPTION_IDS variable is empty or not found"
            }
        } else {
            $targetSubscriptions = $SubscriptionIds
        }

        # Parse subscription IDs from comma-separated string
        $parsedSubscriptionIds = @($targetSubscriptions -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne "" -and $_.Length -ge 30 })
        
        # Ensure we have valid subscription IDs
        if ($parsedSubscriptionIds.Count -eq 0) {
            # Fallback: try to extract using regex
            $guidPattern = '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}'
            $regexMatches = [regex]::Matches($targetSubscriptions, $guidPattern)
            if ($regexMatches.Count -gt 0) {
                $parsedSubscriptionIds = @($regexMatches | ForEach-Object { $_.Value })
            }
        }
        
        if ($parsedSubscriptionIds.Count -eq 0) {
            throw "No valid subscription IDs found in: '$targetSubscriptions'"
        }

        Write-Output "Processing $($parsedSubscriptionIds.Count) subscription(s): $($parsedSubscriptionIds -join ', ')"
    } catch {
        Write-Error "Failed to get target subscriptions: $($_.Exception.Message)"
        throw
    }

    # Get workspace ID and email recipients from automation variables
    try {
        $workspaceResourceId = Get-ConfigurationVariable -Name "LOG_ANALYTICS_WORKSPACE_ID"
        $emailRecipients = Get-ConfigurationVariable -Name "COST_REPORT_RECIPIENTS"

        if (-not $workspaceResourceId -or $workspaceResourceId.Trim() -eq "") {
            throw "LOG_ANALYTICS_WORKSPACE_ID variable not found or is empty"
        }

        # Convert resource ID to workspace customer ID if needed
        if ($workspaceResourceId -match "/subscriptions/(.*)/resourceGroups/(.*)/providers/Microsoft.OperationalInsights/workspaces/(.*)") {
            $workspaceName = $matches[3]
            $resourceGroupName = $matches[2]
            $subscriptionId = $matches[1]
            
            Write-Output "Converting workspace resource ID to customer ID..."
            Write-Output "  Subscription: $subscriptionId"
            Write-Output "  Resource Group: $resourceGroupName"
            Write-Output "  Workspace Name: $workspaceName"
            
            # Set the correct subscription context
            Set-AzContext -SubscriptionId $subscriptionId
            
            # Get the workspace object to extract the customer ID
            $workspace = Get-AzOperationalInsightsWorkspace -ResourceGroupName $resourceGroupName -Name $workspaceName
            $workspaceId = $workspace.CustomerId
            Write-Output "Converted to workspace customer ID: $workspaceId"
        } else {
            # Assume it's already a workspace customer ID
            $workspaceId = $workspaceResourceId
            Write-Output "Using workspace customer ID from variable: $workspaceId"
        }

        # Validate workspace ID format (should be a GUID)
        if ($workspaceId -notmatch '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$') {
            Write-Warning "Workspace ID format may be invalid: $workspaceId"
        }

        Write-Output "Log Analytics Workspace ID: $workspaceId"
        Write-Output "Email Recipients: $(if($emailRecipients){$emailRecipients}else{'Not configured'})"
    } catch {
        Write-Error "Failed to get automation variables: $($_.Exception.Message)"
        throw
    }

        # Auto-discover available subscriptions in cost data
        Write-Output "Discovering available subscriptions in cost data..."
        $discoveryQuery = @"
AzureCostData_CL
| where TimeGenerated >= ago(30d)
| summarize RecordCount = count(), LatestData = max(TimeGenerated) by SubscriptionId
| order by RecordCount desc
"@
        
        try {
            $availableSubscriptions = Invoke-LogAnalyticsQuery -WorkspaceId $workspaceId -Query $discoveryQuery -QueryName "Subscription Discovery"
            
            if ($availableSubscriptions.Count -gt 0) {
                Write-Output "Available subscriptions in cost data:"
                $foundTargets = @()
                $alternativeTargets = @()
                
                foreach ($availableSub in $availableSubscriptions) {
                    $subId = $availableSub.SubscriptionId
                    $recordCount = if ($availableSub.RecordCount) { $availableSub.RecordCount } else { "0" }
                    $latestData = if ($availableSub.LatestData) { $availableSub.LatestData } else { "No data" }
                    
                    if ($parsedSubscriptionIds -contains $subId) {
                        Write-Output "   ${subId}: $recordCount records (TARGETED - Latest: $latestData)"
                        $foundTargets += $subId
                    } else {
                        Write-Output "  ⚙️ ${subId}: $recordCount records (Available alternative - Latest: $latestData)"
                        $alternativeTargets += $subId
                    }
                }
                
                # Update parsed subscription IDs based on what's actually available
                if ($foundTargets.Count -eq 0) {
                    Write-Warning "None of the target subscriptions found in cost data!"
                    Write-Output "Target subscriptions: $($parsedSubscriptionIds -join ', ')"
                    
                    if ($alternativeTargets.Count -gt 0) {
                        Write-Output "Using available alternative subscriptions for cost analysis..."
                        $parsedSubscriptionIds = $alternativeTargets | Select-Object -First 3
                        Write-Output "Alternative subscriptions: $($parsedSubscriptionIds -join ', ')"
                    } else {
                        Write-Warning "No cost data available for any subscriptions in the last 30 days"
                        # Continue with original target IDs for other data sources
                    }
                } else {
                    Write-Output "Found $($foundTargets.Count) of $($parsedSubscriptionIds.Count) target subscriptions in cost data"
                    if ($foundTargets.Count -lt $parsedSubscriptionIds.Count) {
                        $missingTargets = $parsedSubscriptionIds | Where-Object { $_ -notin $foundTargets }
                        Write-Warning "Missing target subscriptions in cost data: $($missingTargets -join ', ')"
                    }
                    # Use only the found target subscriptions for cost queries
                    $parsedSubscriptionIds = $foundTargets
                }
            } else {
                Write-Warning "No cost data found in the last 30 days for any subscriptions"
            }
        } catch {
            Write-Warning "Failed to discover available subscriptions: $($_.Exception.Message)"
            Write-Output "Continuing with original target subscriptions..."
        }

        Write-Output "Processing $($parsedSubscriptionIds.Count) subscription(s): $($parsedSubscriptionIds -join ', ')"    # Enhanced comprehensive queries with multi-subscription support and better error handling
    # Build subscription filter dynamically - Fixed for Azure Automation compatibility
    $subscriptionFilter = ($parsedSubscriptionIds | ForEach-Object { "'$_'" }) -join ','
    
    # 1. Current week cost data with detailed breakdowns - FIXED with correct column suffixes
    $costQuery = @"
AzureCostData_CL
| where TimeGenerated >= ago(7d)
| where SubscriptionId in ($subscriptionFilter)
| where isnotempty(ServiceName_s) and isnotempty(Cost_d) and Cost_d > 0
| where ServiceName_s != "" and ServiceName_s != "global"
| summarize
    TotalCost = sum(Cost_d),
    AvgDailyCost = avg(Cost_d),
    ResourceCount = dcount(ResourceName_s),
    IsAVD = any(IsAVDResource_b),
    MinCost = min(Cost_d),
    MaxCost = max(Cost_d),
    P95Cost = percentile(Cost_d, 95)
    by ServiceName_s, tostring(ResourceType), SubscriptionId, MeterCategory_s, Location_s
| where TotalCost > 0
| order by TotalCost desc
| limit 50
"@

    # 2. Daily cost trends for the last 30 days - FIXED with correct column suffixes
    $dailyCostTrendsQuery = @"
AzureCostData_CL
| where TimeGenerated >= ago(30d)
| where SubscriptionId in ($subscriptionFilter)
| where isnotempty(Cost_d) and Cost_d > 0
| extend CostDate = format_datetime(TimeGenerated, 'yyyy-MM-dd')
| summarize
    DailyCost = sum(Cost_d),
    ServiceCount = dcount(ServiceName_s),
    ResourceCount = dcount(ResourceName_s),
    AVDCost = sum(iff(IsAVDResource_b == true, Cost_d, 0.0)),
    NonAVDCost = sum(iff(IsAVDResource_b != true, Cost_d, 0.0))
    by CostDate, SubscriptionId
| where DailyCost > 0
| order by CostDate desc
"@

    # 3. Service-level cost analysis with growth metrics - FIXED without problematic pivot
    $serviceCostAnalysisQuery = @"
let currentWeekData = AzureCostData_CL
| where TimeGenerated >= ago(7d)
| where SubscriptionId in ($subscriptionFilter)
| where isnotempty(ServiceName_s) and isnotempty(Cost_d) and Cost_d > 0
| summarize CurrentWeekCost = sum(Cost_d) by ServiceName_s, SubscriptionId;
let previousWeekData = AzureCostData_CL
| where TimeGenerated >= ago(14d) and TimeGenerated < ago(7d)
| where SubscriptionId in ($subscriptionFilter)
| where isnotempty(ServiceName_s) and isnotempty(Cost_d) and Cost_d > 0
| summarize PreviousWeekCost = sum(Cost_d) by ServiceName_s, SubscriptionId;
currentWeekData
| join kind=fullouter previousWeekData on ServiceName_s, SubscriptionId
| extend
    CurrentWeek = coalesce(CurrentWeekCost, 0.0),
    PreviousWeek = coalesce(PreviousWeekCost, 0.0)
| extend
    WeeklyGrowth = iff(PreviousWeek > 0, ((CurrentWeek - PreviousWeek) / PreviousWeek) * 100, 0.0),
    AbsoluteChange = CurrentWeek - PreviousWeek
| where CurrentWeek > 0
| project ServiceName_s, SubscriptionId, CurrentWeek, PreviousWeek, WeeklyGrowth, AbsoluteChange
| order by CurrentWeek desc
| take 20
"@

    # 4. Historical baseline data for trend comparison - FIXED with correct column suffixes
    $baselineQuery = @"
AzureCostBaseline_CL
| where TimeGenerated >= ago(30d)
| where SubscriptionId in ($subscriptionFilter)
| where isnotempty(AverageMonthlySpend_d) and AverageMonthlySpend_d > 0
| top 1 by TimeGenerated desc
| project
    AverageMonthlySpend = AverageMonthlySpend_d,
    MedianMonthlySpend = coalesce(MedianMonthlySpend_d, AverageMonthlySpend_d),
    MonthlyGrowthRate = coalesce(MonthlyGrowthRate_d, 0.0),
    TrendDirection = coalesce(TrendDirection_s, "Unknown"),
    ProjectedNextMonth = coalesce(ProjectedNextMonth_d, AverageMonthlySpend_d),
    SubscriptionId
"@

    # 5. Historical cost trends for comparison - FIXED with correct column suffixes
    $historicalTrendQuery = @"
AzureHistoricalCostData_CL
| where TimeGenerated >= ago(90d)
| where SubscriptionId in ($subscriptionFilter)
| where isnotempty(BillingMonth_s) and isnotempty(TotalCost_d) and TotalCost_d > 0
| extend BillingMonth = BillingMonth_s
| summarize
    MonthlySpend = sum(TotalCost_d),
    RecordCount = count(),
    AvgDailyCost = avg(TotalCost_d),
    MinCost = min(TotalCost_d),
    MaxCost = max(TotalCost_d)
    by BillingMonth, SubscriptionId
| where MonthlySpend > 0
| order by BillingMonth desc
| limit 50
"@

    # 6. Invoice data collection removed - was not providing useful data
    # Skip invoice validation due to API limitations with pay-as-you-go subscriptions

    # 7. Performance data for rightsizing analysis (enhanced with more metrics)
    $performanceQuery = @"
Perf
| where TimeGenerated >= ago(7d)
| where ObjectName in ("Processor", "Memory", "LogicalDisk", "Network Interface")
| where CounterName in (
    "% Processor Time",
    "% Committed Bytes In Use",
    "Available Bytes",
    "% Disk Time",
    "Bytes Total/sec",
    "% Free Space",
    "Disk Bytes/sec",
    "Packets/sec"
)
| summarize
    AvgValue = avg(CounterValue),
    MaxValue = max(CounterValue),
    MinValue = min(CounterValue),
    P95Value = percentile(CounterValue, 95),
    P99Value = percentile(CounterValue, 99),
    SampleCount = count(),
    StdDev = stdev(CounterValue)
    by Computer, ObjectName, CounterName, InstanceName
| order by Computer, ObjectName, CounterName
"@

    # 8. VM rightsizing opportunities (enhanced with more detailed analysis)
    $rightsizingQuery = @"
let cpuData = Perf
| where TimeGenerated >= ago(7d)
| where ObjectName == "Processor" and CounterName == "% Processor Time" and InstanceName == "_Total"
| summarize
    AvgCPU = avg(CounterValue),
    MaxCPU = max(CounterValue),
    P95CPU = percentile(CounterValue, 95),
    P99CPU = percentile(CounterValue, 99),
    MinCPU = min(CounterValue),
    CPUSamples = count()
    by Computer;
let memoryData = Perf
| where TimeGenerated >= ago(7d)
| where ObjectName == "Memory" and CounterName == "% Committed Bytes In Use"
| summarize
    AvgMemory = avg(CounterValue),
    MaxMemory = max(CounterValue),
    P95Memory = percentile(CounterValue, 95),
    P99Memory = percentile(CounterValue, 99),
    MinMemory = min(CounterValue),
    MemorySamples = count()
    by Computer;
let diskData = Perf
| where TimeGenerated >= ago(7d)
| where ObjectName == "LogicalDisk" and CounterName == "% Disk Time" and InstanceName == "_Total"
| summarize
    AvgDisk = avg(CounterValue),
    MaxDisk = max(CounterValue),
    P95Disk = percentile(CounterValue, 95)
    by Computer;
cpuData
| join kind=leftouter memoryData on Computer
| join kind=leftouter diskData on Computer
| extend
    CPUUtilizationCategory = case(
        AvgCPU < 5, "Severely Underutilized",
        AvgCPU < 15, "Underutilized",
        AvgCPU < 40, "Low Utilized",
        AvgCPU < 60, "Well Utilized",
        AvgCPU < 80, "Highly Utilized",
        "Over Utilized"
    ),
    MemoryUtilizationCategory = case(
        AvgMemory < 20, "Severely Underutilized",
        AvgMemory < 40, "Underutilized",
        AvgMemory < 60, "Low Utilized",
        AvgMemory < 75, "Well Utilized",
        AvgMemory < 90, "Highly Utilized",
        "Over Utilized"
    ),
    DiskUtilizationCategory = case(
        AvgDisk < 20, "Low Disk Usage",
        AvgDisk < 50, "Moderate Disk Usage",
        AvgDisk < 80, "High Disk Usage",
        "Very High Disk Usage"
    ),
    RightsizingRecommendation = case(
        AvgCPU < 5 and AvgMemory < 20, "Strong candidate for downsizing - Both CPU and Memory severely underutilized",
        AvgCPU < 15 and AvgMemory < 40, "Consider downsizing - Low utilization across CPU and Memory",
        AvgCPU < 15 and AvgMemory >= 75, "Mixed utilization - CPU underutilized but Memory well used",
        AvgCPU >= 75 and AvgMemory < 40, "Mixed utilization - CPU well used but Memory underutilized",
        AvgCPU > 80 or AvgMemory > 90, "Consider upsizing - High utilization detected",
        P95CPU > 90 or P95Memory > 95, "Consider upsizing - Peak utilization very high",
        "Current size appears appropriate"
    ),
    UtilizationScore = (AvgCPU + AvgMemory) / 2,
    PeakUtilizationScore = (P95CPU + P95Memory) / 2
| project Computer, AvgCPU, MaxCPU, P95CPU, P99CPU, AvgMemory, MaxMemory, P95Memory, P99Memory,
          AvgDisk, MaxDisk, P95Disk, CPUUtilizationCategory, MemoryUtilizationCategory, DiskUtilizationCategory,
          RightsizingRecommendation, UtilizationScore, PeakUtilizationScore, CPUSamples, MemorySamples
| order by UtilizationScore asc, AvgCPU asc, AvgMemory asc
"@

    # 9. Resource inventory and cost correlation - FIXED with correct column suffixes
    $resourceInventoryQuery = @"
AzureCostData_CL
| where TimeGenerated >= ago(7d)
| where SubscriptionId in ($subscriptionFilter)
| where isnotempty(ResourceName_s) and isnotempty(Cost_d) and Cost_d > 0
| summarize
    TotalCost = sum(Cost_d),
    AvgDailyCost = avg(Cost_d),
    DaysWithCost = dcount(format_datetime(TimeGenerated, 'yyyy-MM-dd')),
    IsAVD = any(IsAVDResource_b),
    FirstSeen = min(TimeGenerated),
    LastSeen = max(TimeGenerated)
    by ResourceName_s, tostring(ResourceType), ServiceName_s, Location_s, SubscriptionId
| where TotalCost > 0
| extend
    ResourceAge = datetime_diff('day', now(), FirstSeen),
    CostEfficiency = TotalCost / DaysWithCost,
    ResourceCategory = case(
        tostring(ResourceType) contains "VirtualMachine", "Compute",
        tostring(ResourceType) contains "Storage", "Storage",
        tostring(ResourceType) contains "Network", "Networking",
        tostring(ResourceType) contains "Database", "Database",
        "Other"
    )
| order by TotalCost desc
"@

    # 10. Cost anomaly detection - SIMPLIFIED to avoid prev() function issues
    $costAnomalyQuery = @"
AzureCostData_CL
| where TimeGenerated >= ago(30d)
| where SubscriptionId in ($subscriptionFilter)
| where isnotempty(ServiceName_s) and isnotempty(Cost_d) and Cost_d > 0
| extend CostDate = format_datetime(TimeGenerated, 'yyyy-MM-dd')
| summarize DailyCost = sum(Cost_d) by CostDate, ServiceName_s, SubscriptionId
| where DailyCost > 100
| extend DaysAgo = datetime_diff('day', now(), todatetime(strcat(CostDate, "T00:00:00Z")))
| where DaysAgo <= 30
| extend AnomalyType = case(
    DailyCost > 2000, "Significant Spike",
    DailyCost > 1000, "Moderate Increase",
    DailyCost > 500, "Above Average",
    "Normal"
)
| where AnomalyType in ("Significant Spike", "Moderate Increase")
| project CostDate, ServiceName_s, SubscriptionId, DailyCost, AnomalyType, DayOverDayChange = 0.0, DayOverDayAbsolute = 0.0
| order by DailyCost desc
| take 10
"@

    # Check table existence before executing queries
    Write-Output "Checking Log Analytics table availability..."
    $requiredTables = @("AzureCostData_CL", "Perf")
    $optionalTables = @("AzureCostBaseline_CL", "AzureHistoricalCostData_CL")
    # Removed AzureInvoiceData_CL - invoice collection deprecated due to API limitations

    $availableTables = @{}
    foreach ($table in ($requiredTables + $optionalTables)) {
        $exists = Test-LogAnalyticsTable -WorkspaceId $workspaceId -TableName $table
        $availableTables[$table] = $exists
        Write-Output "$table $(if($exists){' Available'}else{' Not found'})"
    }

    # Add a data inspection query for debugging - FIXED with correct suffixes
    $dataInspectionQuery = @"
AzureCostData_CL
| where TimeGenerated >= ago(7d)
| where SubscriptionId in ($subscriptionFilter)
| where Cost_d > 0
| summarize 
    TotalRecords = count(),
    TotalCost = sum(Cost_d),
    UniqueServices = dcount(ServiceName_s),
    UniqueResources = dcount(ResourceName_s),
    AVDResources = countif(IsAVDResource_b == true),
    NonAVDResources = countif(IsAVDResource_b != true),
    DateRange = strcat(format_datetime(min(TimeGenerated), 'yyyy-MM-dd'), ' to ', format_datetime(max(TimeGenerated), 'yyyy-MM-dd'))
    by SubscriptionId
| order by TotalCost desc
"@

    Write-Output "Inspecting AzureCostData_CL table structure..."
    if ($availableTables["AzureCostData_CL"]) {
        $sampleData = Invoke-LogAnalyticsQuery -WorkspaceId $workspaceId -Query $dataInspectionQuery -QueryName "Data Structure Inspection"
        if ($sampleData.Count -gt 0) {
            Write-Output "Sample data found - table is accessible and contains data for target subscriptions"
        } else {
            Write-Warning "No data found in AzureCostData_CL for the specified subscriptions and time range"
        }
    }

    # Execute queries in logical groups with appropriate delays
    Write-Output "Collecting cost and financial data..."

    # Initialize all data variables
    $costData = @()
    $dailyCostTrends = @()
    $serviceCostAnalysis = @()
    $baselineData = @()
    $historicalData = @()
    $invoiceData = @()
    $performanceData = @()
    $rightsizingData = @()
    $resourceInventory = @()
    $costAnomalies = @()
    $simpleCostResults = @()

    # Execute cost data queries only if table exists and we have valid subscriptions
    if ($availableTables["AzureCostData_CL"] -and $parsedSubscriptionIds.Count -gt 0) {
        Write-Output "Executing cost data queries for $($parsedSubscriptionIds.Count) subscription(s)..."
        
        # First, execute a simple test query to debug the cost calculation - FIXED with correct suffixes
        $simpleCostTestQuery = @"
AzureCostData_CL
| where TimeGenerated >= ago(7d)
| where SubscriptionId in ($subscriptionFilter)
| where Cost_d > 0
| summarize
    TotalWeeklyCost = sum(Cost_d),
    RecordCount = count(),
    UniqueServices = dcount(ServiceName_s),
    AVDCost = sum(iff(IsAVDResource_b == true, Cost_d, 0.0)),
    NonAVDCost = sum(iff(IsAVDResource_b != true, Cost_d, 0.0))
"@
        $simpleCostResults = Invoke-LogAnalyticsQuery -WorkspaceId $workspaceId -Query $simpleCostTestQuery -QueryName "Simple Cost Test"
        
        Write-Output "Simple Cost Test Results:"
        if ($simpleCostResults.Count -gt 0) {
            $simpleCost = $simpleCostResults[0]
            Write-Output "Total Weekly Cost: $(if($simpleCost.TotalWeeklyCost){$simpleCost.TotalWeeklyCost}else{'[No data]'})"
            Write-Output "Record Count: $(if($simpleCost.RecordCount){$simpleCost.RecordCount}else{'[No data]'})"
            Write-Output "Unique Services: $(if($simpleCost.UniqueServices){$simpleCost.UniqueServices}else{'[No data]'})"
            Write-Output "AVD Cost: $(if($simpleCost.AVDCost -ne $null){$simpleCost.AVDCost}else{'[No data]'})"
            Write-Output "Non-AVD Cost: $(if($simpleCost.NonAVDCost){$simpleCost.NonAVDCost}else{'[No data]'})"
        } else {
            Write-Output "Total Weekly Cost: [No data returned]"
            Write-Output "Record Count: [No data returned]"
            Write-Output "Unique Services: [No data returned]"
            Write-Output "AVD Cost: [No data returned]"
            Write-Output "Non-AVD Cost: [No data returned]"
        }
        Start-Sleep -Seconds 2
        
        $costData = Invoke-LogAnalyticsQuery -WorkspaceId $workspaceId -Query $costQuery -QueryName "Current Cost Data"
        if ($costData.Count -eq 0) {
            Write-Warning "Current cost query returned 0 records. This may indicate:"
            Write-Warning "  - No cost data for the last 7 days"
            Write-Warning "  - Subscription IDs don't match data format"
            Write-Warning "  - Data collection issues"
        }
        Start-Sleep -Seconds 3

        $dailyCostTrends = Invoke-LogAnalyticsQuery -WorkspaceId $workspaceId -Query $dailyCostTrendsQuery -QueryName "Daily Cost Trends"
        Start-Sleep -Seconds 3

        $serviceCostAnalysis = Invoke-LogAnalyticsQuery -WorkspaceId $workspaceId -Query $serviceCostAnalysisQuery -QueryName "Service Cost Analysis"
        Start-Sleep -Seconds 3

        $resourceInventory = Invoke-LogAnalyticsQuery -WorkspaceId $workspaceId -Query $resourceInventoryQuery -QueryName "Resource Inventory"
        Start-Sleep -Seconds 3

        $costAnomalies = Invoke-LogAnalyticsQuery -WorkspaceId $workspaceId -Query $costAnomalyQuery -QueryName "Cost Anomalies"
        Start-Sleep -Seconds 3
    } else {
        if (-not $availableTables["AzureCostData_CL"]) {
            Write-Warning "AzureCostData_CL table not found. Cost analysis will be limited."
        }
        if ($parsedSubscriptionIds.Count -eq 0) {
            Write-Warning "No valid subscription IDs available for cost analysis."
        }
        Write-Output "Skipping cost data queries due to missing table or subscription data."
    }

    # Execute optional table queries
    if ($availableTables["AzureCostBaseline_CL"]) {
        $baselineData = Invoke-LogAnalyticsQuery -WorkspaceId $workspaceId -Query $baselineQuery -QueryName "Baseline Data"
        Start-Sleep -Seconds 3
    }

    if ($availableTables["AzureHistoricalCostData_CL"]) {
        $historicalData = Invoke-LogAnalyticsQuery -WorkspaceId $workspaceId -Query $historicalTrendQuery -QueryName "Historical Trends"
        Start-Sleep -Seconds 3
    }

    # Invoice data collection removed - no longer available

    Write-Output "Collecting performance and rightsizing data..."
    if ($availableTables["Perf"]) {
        $performanceData = Invoke-LogAnalyticsQuery -WorkspaceId $workspaceId -Query $performanceQuery -QueryName "Performance Metrics"
        Start-Sleep -Seconds 3

        $rightsizingData = Invoke-LogAnalyticsQuery -WorkspaceId $workspaceId -Query $rightsizingQuery -QueryName "VM Rightsizing"
        Start-Sleep -Seconds 3
    } else {
        Write-Warning "Perf table not found. VM rightsizing analysis will not be available."
    }

    Write-Output "Comprehensive query execution completed:"
    Write-Output "  Current cost records: $($costData.Count)"
    Write-Output "  Daily cost trend records: $($dailyCostTrends.Count)"
    Write-Output "  Service cost analysis records: $($serviceCostAnalysis.Count)"
    Write-Output "  Baseline records: $($baselineData.Count)"
    Write-Output "  Historical records: $($historicalData.Count)"
    Write-Output "  Performance records: $($performanceData.Count)"
    Write-Output "  Rightsizing records: $($rightsizingData.Count)"
    Write-Output "  Resource inventory records: $($resourceInventory.Count)"
    Write-Output "  Cost anomaly records: $($costAnomalies.Count)"
    # Note: Invoice data collection removed

    # Calculate summary metrics with baseline comparison and multi-subscription aggregation
    if ($costData.Count -gt 0) {
        # Fixed total cost calculation with better error handling
        try {
            # Use a more robust approach to calculate totals
            $totalCost = 0
            foreach ($item in $costData) {
                try {
                    if ($item.TotalCost -ne $null) {
                        $totalCost += [double]$item.TotalCost
                    }
                } catch {
                    Write-Warning "Could not parse TotalCost value: $($item.TotalCost)"
                }
            }
            
            Write-Output "Calculated total cost from detailed data: $($totalCost.ToString('C2'))"
        } catch {
            Write-Warning "Error calculating total cost from detailed data: $($_.Exception.Message)"
            $totalCost = 0
        }
        
        # If still zero and we have simple cost results, use those
        if ($totalCost -eq 0 -and $simpleCostResults.Count -gt 0) {
            try {
                $totalCost = [double]$simpleCostResults[0].TotalWeeklyCost
                Write-Output "Using simple cost calculation: $($totalCost.ToString('C2'))"
            } catch {
                Write-Warning "Could not parse simple total cost: $($simpleCostResults[0].TotalWeeklyCost)"
                $totalCost = 0
            }
        }
        
        # Safe calculation of AVD cost with null checks and improved error handling
        try {
            $avdCost = 0
            foreach ($item in $costData) {
                try {
                    if ($item.IsAVD -eq $true -and $item.TotalCost -ne $null) {
                        $avdCost += [double]$item.TotalCost
                    }
                } catch {
                    Write-Warning "Could not parse AVD TotalCost value: $($item.TotalCost)"
                }
            }
            
            # If still zero and we have simple cost results, use those
            if ($avdCost -eq 0 -and $simpleCostResults.Count -gt 0) {
                try {
                    $avdCost = [double]$simpleCostResults[0].AVDCost
                    Write-Output "Using simple AVD cost calculation: $($avdCost.ToString('C2'))"
                } catch {
                    Write-Warning "Could not parse simple AVD cost: $($simpleCostResults[0].AVDCost)"
                    $avdCost = 0
                }
            }
        } catch {
            Write-Warning "Error calculating AVD cost: $($_.Exception.Message)"
            $avdCost = 0
        }
        
        $nonAvdCost = $totalCost - $avdCost

        # Aggregate baseline data across subscriptions with better error handling
        if ($baselineData.Count -gt 0) {
            try {
                $avgMonthlySpend = 0
                $validBaselineItems = 0
                foreach ($item in $baselineData) {
                    try {
                        if ($item.AverageMonthlySpend -ne $null) {
                            $avgMonthlySpend += [double]$item.AverageMonthlySpend
                            $validBaselineItems++
                        }
                    } catch {
                        Write-Warning "Could not parse AverageMonthlySpend value: $($item.AverageMonthlySpend)"
                    }
                }
                if ($validBaselineItems -gt 0) {
                    $avgMonthlySpend = $avgMonthlySpend / $validBaselineItems
                }
            } catch {
                Write-Warning "Error calculating baseline average: $($_.Exception.Message)"
                $avgMonthlySpend = 0
            }
            
            $projectedWeeklyCost = if ($avgMonthlySpend -gt 0) { $avgMonthlySpend / 4.33 } else { 0 }  # Average weeks per month
            $costVariance = if ($projectedWeeklyCost -gt 0) { (($totalCost - $projectedWeeklyCost) / $projectedWeeklyCost) * 100 } else { 0 }
            
            # Safe trend direction calculation
            $trendDirections = $baselineData | Where-Object { $_.TrendDirection -ne $null -and $_.TrendDirection -ne "" } | ForEach-Object { $_.TrendDirection }
            $trendDirection = if ($trendDirections) { ($trendDirections | Group-Object | Sort-Object Count -Descending | Select-Object -First 1).Name } else { "Unknown" }
        } else {
            $projectedWeeklyCost = 0
            $costVariance = 0
            $trendDirection = "Unknown"
        }

        Write-Output "Cost Analysis Summary:"
        Write-Output "  Total Weekly Cost: $($totalCost.ToString('C2'))"
        Write-Output "  AVD Cost: $($avdCost.ToString('C2'))"
        Write-Output "  Non-AVD Cost: $($nonAvdCost.ToString('C2'))"
        Write-Output "  Cost Variance from Baseline: $($costVariance.ToString('F1'))%"
        Write-Output "  Trend Direction: $trendDirection"
    } else {
        # Check if we have simple cost results even when detailed cost data is empty
        if ($simpleCostResults.Count -gt 0) {
            try {
                $totalCost = [double]$simpleCostResults[0].TotalWeeklyCost
                $avdCost = [double]$simpleCostResults[0].AVDCost
                $nonAvdCost = [double]$simpleCostResults[0].NonAVDCost
                Write-Output "Using fallback simple cost calculation due to detailed query failure"
            } catch {
                Write-Warning "Could not parse simple cost results, using zero values"
                $totalCost = 0
                $avdCost = 0
                $nonAvdCost = 0
            }
        } else {
            $totalCost = 0
            $avdCost = 0
            $nonAvdCost = 0
        }
        
        $projectedWeeklyCost = 0
        $costVariance = 0
        $trendDirection = "Unknown"
        
        if ($totalCost -gt 0) {
            Write-Output "Cost Analysis Summary (Fallback):"
            Write-Output "  Total Weekly Cost: $($totalCost.ToString('C2'))"
            Write-Output "  AVD Cost: $($avdCost.ToString('C2'))"
            Write-Output "  Non-AVD Cost: $($nonAvdCost.ToString('C2'))"
        } else {
            Write-Warning "No cost data available for analysis"
        }
    }

    # Calculate VM rightsizing metrics with null checks
    $underutilizedVMs = @()
    $overutilizedVMs = @()
    
    if ($rightsizingData.Count -gt 0) {
        $underutilizedVMs = @($rightsizingData | Where-Object { 
            $_.RightsizingRecommendation -ne $null -and (
                $_.RightsizingRecommendation -like "*downsizing*" -or 
                $_.CPUUtilizationCategory -eq "Severely Underutilized"
            )
        })
        $overutilizedVMs = @($rightsizingData | Where-Object { 
            $_.RightsizingRecommendation -ne $null -and (
                $_.RightsizingRecommendation -like "*upsizing*" -or 
                $_.CPUUtilizationCategory -eq "Over Utilized"
            )
        })
    }

    Write-Output "Performance Analysis Summary:"
    Write-Output "  VMs Analyzed: $($rightsizingData.Count)"
    Write-Output "  Underutilized VMs: $($underutilizedVMs.Count)"
    Write-Output "  Overutilized VMs: $($overutilizedVMs.Count)"

    # Prepare comprehensive enhanced data for AI analysis with all collected metrics
    # Convert to JSON with error handling for null or empty collections
    $costDataJson = if ($costData.Count -gt 0) { $costData | ConvertTo-Json -Depth 5 -Compress } else { "[]" }
    $performanceDataJson = if ($performanceData.Count -gt 0) { $performanceData | ConvertTo-Json -Depth 5 -Compress } else { "[]" }
    $rightsizingDataJson = if ($rightsizingData.Count -gt 0) { $rightsizingData | ConvertTo-Json -Depth 5 -Compress } else { "[]" }
    $dailyCostTrendsJson = if ($dailyCostTrends.Count -gt 0) { $dailyCostTrends | ConvertTo-Json -Depth 5 -Compress } else { "[]" }
    $serviceCostAnalysisJson = if ($serviceCostAnalysis.Count -gt 0) { $serviceCostAnalysis | ConvertTo-Json -Depth 5 -Compress } else { "[]" }
    $baselineDataJson = if ($baselineData.Count -gt 0) { $baselineData | ConvertTo-Json -Depth 5 -Compress } else { "[]" }
    $historicalDataJson = if ($historicalData.Count -gt 0) { $historicalData | ConvertTo-Json -Depth 5 -Compress } else { "[]" }
    $resourceInventoryJson = if ($resourceInventory.Count -gt 0) { $resourceInventory | ConvertTo-Json -Depth 5 -Compress } else { "[]" }
    $costAnomaliesJson = if ($costAnomalies.Count -gt 0) { $costAnomalies | ConvertTo-Json -Depth 5 -Compress } else { "[]" }

    # Analyze with Claude AI using comprehensive data from all sources
    $aiAnalysisResults = Invoke-ClaudeAnalysis `
        -CostDataJson $costDataJson `
        -PerformanceDataJson $performanceDataJson `
        -RightsizingDataJson $rightsizingDataJson `
        -DailyCostTrendsJson $dailyCostTrendsJson `
        -ServiceCostAnalysisJson $serviceCostAnalysisJson `
        -BaselineDataJson $baselineDataJson `
        -HistoricalDataJson $historicalDataJson `
        -ResourceInventoryJson $resourceInventoryJson `
        -CostAnomaliesJson $costAnomaliesJson `
        -AnalysisType "comprehensive_weekly_analysis"

    # Create comprehensive report data hashtable with all collected data
    $reportData = @{
        TotalCost = $totalCost
        AvdCost = $avdCost
        NonAvdCost = $nonAvdCost
        SubscriptionIds = $parsedSubscriptionIds
        RightsizingData = $rightsizingData
        UnderutilizedVMs = $underutilizedVMs
        CostVariance = $costVariance
        CostAnomalies = $costAnomalies
        ResourceInventory = $resourceInventory
        CostData = $costData
        ServiceCostAnalysis = $serviceCostAnalysis
        AiAnalysisResults = $aiAnalysisResults
        PerformanceData = $performanceData
        HistoricalData = $historicalData
        BaselineData = $baselineData
        DailyCostTrends = $dailyCostTrends
        TrendDirection = $trendDirection
        ProjectedWeeklyCost = $projectedWeeklyCost
        OverutilizedVMs = $overutilizedVMs
    }

    # Generate HTML report using the new function
    $htmlReport = New-HtmlReport -ReportData $reportData

    # Send email report with enhanced error handling
    if ($emailRecipients) {
        $emailSubject = "Weekly Azure Cost Analysis - $(Get-Date -Format 'MMM dd, yyyy') - ($($parsedSubscriptionIds.Count) subs)"
        Send-EmailNotification -Subject $emailSubject -HtmlBody $htmlReport -Recipients $emailRecipients -BodyType "HTML"
    } else {
        Write-Warning "No email recipients configured. Skipping email notification."
    }

    Write-Output "Comprehensive weekly cost analysis completed successfully"
    Write-Output ""
    Write-Output "=== COMPREHENSIVE ANALYSIS SUMMARY ==="
    Write-Output " Financial Metrics:"
    Write-Output "  Subscriptions Processed: $($parsedSubscriptionIds.Count)"
    Write-Output "  Total Weekly Cost: $($totalCost.ToString('C2'))"
    Write-Output "  AVD Cost: $($avdCost.ToString('C2')) ($(if($totalCost -gt 0){($avdCost / $totalCost * 100).ToString('F1')}else{0})%)"
    Write-Output "  Non-AVD Cost: $($nonAvdCost.ToString('C2'))"
    Write-Output "  Baseline Variance: $($costVariance.ToString('F1'))%"
    Write-Output "  Trend Direction: $trendDirection"
    Write-Output ""
    Write-Output "💻 Performance & Rightsizing:"
    Write-Output "  VMs Performance Monitored: $($rightsizingData.Count)"
    Write-Output "  Underutilized VMs: $($underutilizedVMs.Count)"
    Write-Output "  Overutilized VMs: $($overutilizedVMs.Count)"
    Write-Output "  Performance Metrics Collected: $($performanceData.Count)"
    Write-Output ""
    Write-Output " Data Coverage:"
    Write-Output "  Current Cost Services: $($costData.Count)"
    Write-Output "  Daily Cost Trends: $($dailyCostTrends.Count)"
    Write-Output "  Service Growth Analysis: $($serviceCostAnalysis.Count)"
    Write-Output "  Resource Inventory: $($resourceInventory.Count)"
    Write-Output "  Cost Anomalies Detected: $($costAnomalies.Count)"
    Write-Output "  Historical Records: $($historicalData.Count)"
    Write-Output "  Baseline Records: $($baselineData.Count)"
    
    if ($emailRecipients) {
        Write-Output ""
        Write-Output "📧 Email Report: Sent successfully to $emailRecipients"
    }

    Write-Output ""
    Write-Output "=== ANALYSIS COMPLETE ==="

} catch {
    Write-Error "Comprehensive weekly analysis failed: $($_.Exception.Message)"
    Write-Error "Stack trace: $($_.ScriptStackTrace)"

    # Send failure notification with enhanced error reporting
    if ($emailRecipients) {
        try {
            $currentDateTime = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
            $subscriptionList = if ($parsedSubscriptionIds) { $parsedSubscriptionIds -join ', ' } else { "Not determined" }

            $failureHtml = @"
<h2 style="color: #d32f2f;"> Weekly Cost Analysis Failed</h2>
<p>The weekly cost analysis encountered an error:</p>
<div style="background: #ffebee; padding: 15px; border-radius: 5px; margin: 10px 0;">
    <strong>Error:</strong> $($_.Exception.Message)
</div>
<div style="background: #f5f5f5; padding: 15px; border-radius: 5px; margin: 10px 0;">
    <strong>Subscriptions being processed:</strong> $subscriptionList
</div>
<p>Please check the Azure Automation logs for detailed information.</p>
<p><em>Report generated: $currentDateTime UTC</em></p>
"@
            Send-EmailNotification -Subject "Weekly Cost Analysis Failed" -HtmlBody $failureHtml -Recipients $emailRecipients -BodyType "HTML"
        } catch {
            Write-Error "Failed to send failure notification: $($_.Exception.Message)"
        }
    }
    throw
}
