# Architecture Diagrams

## System Architecture Overview

```mermaid
graph TB
    subgraph "Azure Subscriptions"
        SUB1[Subscription 1<br/>Production]
        SUB2[Subscription 2<br/>Development]
        SUB3[Subscription N<br/>Additional]
    end
    
    subgraph "Cost Management APIs"
        COST_API[Azure Cost<br/>Management API]
        BUDGET_API[Budget API]
        ADVISOR_API[Advisor API]
    end
    
    subgraph "Management Subscription"
        subgraph "Resource Group: rg-nip-costing-dev-eus"
            AA[Automation Account<br/>aa-nip-costing-dev-eus]
            LAW[Log Analytics<br/>law-nip-costing-dev-eus]
            SA[Storage Account<br/>stnipcostingdev****]
            KV[Key Vault<br/>kv-dev-cost-****]
        end
    end
    
    subgraph "External Services"
        CLAUDE[Claude 3.5 Haiku<br/>Anthropic API]
        GRAPH[Microsoft Graph<br/>Email API]
    end
    
    subgraph "Data Tables"
        COST_TABLE[AzureCostData_CL]
        BASELINE_TABLE[AzureCostBaseline_CL]
        HISTORY_TABLE[AzureHistoricalCostData_CL]
    end
    
    subgraph "Recipients"
        EMAIL[Email Recipients<br/>Cost Administrators]
    end
    
    SUB1 --> COST_API
    SUB2 --> COST_API
    SUB3 --> COST_API
    
    COST_API --> AA
    BUDGET_API --> AA
    ADVISOR_API --> AA
    
    AA --> LAW
    LAW --> COST_TABLE
    LAW --> BASELINE_TABLE
    LAW --> HISTORY_TABLE
    
    AA --> CLAUDE
    AA --> GRAPH
    AA --> SA
    AA --> KV
    
    GRAPH --> EMAIL
    
    classDef azure fill:#0078d4,stroke:#ffffff,stroke-width:2px,color:#ffffff
    classDef external fill:#ff6b35,stroke:#ffffff,stroke-width:2px,color:#ffffff
    classDef data fill:#28a745,stroke:#ffffff,stroke-width:2px,color:#ffffff
    
    class SUB1,SUB2,SUB3,AA,LAW,SA,KV,COST_API,BUDGET_API,ADVISOR_API azure
    class CLAUDE,GRAPH external
    class COST_TABLE,BASELINE_TABLE,HISTORY_TABLE data
```

## Data Flow Architecture

```mermaid
sequenceDiagram
    participant Scheduler as Azure Scheduler
    participant AA as Automation Account
    participant MI as Managed Identity
    participant COST as Cost Management API
    participant LAW as Log Analytics
    participant CLAUDE as Claude 3.5 Haiku
    participant GRAPH as Microsoft Graph
    participant USERS as Email Recipients
    
    Note over Scheduler,USERS: Daily Cost Collection (02:00 EST)
    
    Scheduler->>AA: Trigger rb-cost-collection
    AA->>MI: Authenticate with Managed Identity
    MI->>COST: Query cost data for subscriptions
    COST->>AA: Return cost data (JSON)
    AA->>AA: Filter AVD resources (name contains "VD")
    AA->>AA: Transform and validate data
    AA->>LAW: Ingest to AzureCostData_CL
    
    Note over Scheduler,USERS: Weekly Analysis (Sunday 06:00 EST)
    
    Scheduler->>AA: Trigger rb-weekly-analysis
    AA->>LAW: Query aggregated cost data
    LAW->>AA: Return cost trends and metrics
    AA->>CLAUDE: Send cost data for AI analysis
    CLAUDE->>AA: Return insights and recommendations
    AA->>AA: Generate HTML email report
    AA->>GRAPH: Send email via Microsoft Graph
    GRAPH->>USERS: Deliver cost report email
```

## Component Interaction Details

```mermaid
graph LR
    subgraph "Authentication Flow"
        AA_AUTH[Automation Account]
        MI_AUTH[System Managed Identity]
        RBAC[RBAC Assignments]
        
        AA_AUTH --> MI_AUTH
        MI_AUTH --> RBAC
    end
    
    subgraph "Data Collection Flow"
        SCHED[Daily Schedule<br/>02:00 EST]
        COLLECT[Cost Collection<br/>Runbook]
        FILTER[AVD Filter<br/>Logic]
        VALIDATE[Data Validation]
        INGEST[Log Analytics<br/>Ingestion]
        
        SCHED --> COLLECT
        COLLECT --> FILTER
        FILTER --> VALIDATE
        VALIDATE --> INGEST
    end
    
    subgraph "Analysis Flow"
        WEEKLY[Weekly Schedule<br/>Sunday 06:00 EST]
        QUERY[Cost Data Query]
        AI_ANALYZE[AI Analysis<br/>Claude 3.5 Haiku]
        REPORT[HTML Report<br/>Generation]
        EMAIL[Email Delivery<br/>Microsoft Graph]
        
        WEEKLY --> QUERY
        QUERY --> AI_ANALYZE
        AI_ANALYZE --> REPORT
        REPORT --> EMAIL
    end
    
    RBAC --> COLLECT
    INGEST --> QUERY
```

## Network Architecture

```mermaid
graph TB
    subgraph "Azure Cloud"
        subgraph "Management Subscription"
            subgraph "East US Region"
                AA[Automation Account]
                LAW[Log Analytics Workspace]
                SA[Storage Account]
                KV[Key Vault]
            end
        end
        
        subgraph "Target Subscriptions"
            SUB1[Subscription 1]
            SUB2[Subscription 2]
            SUBN[Subscription N]
        end
        
        subgraph "Azure APIs"
            COST_API[Cost Management API]
            GRAPH_API[Microsoft Graph API]
        end
    end
    
    subgraph "External Services"
        ANTHROPIC[Anthropic API<br/>Claude 3.5 Haiku]
    end
    
    subgraph "Email Recipients"
        ADMINS[Cost Administrators]
    end
    
    AA -.->|HTTPS| SUB1
    AA -.->|HTTPS| SUB2
    AA -.->|HTTPS| SUBN
    
    AA -.->|HTTPS| COST_API
    AA -.->|HTTPS| GRAPH_API
    AA -.->|HTTPS| ANTHROPIC
    
    AA -->|Azure Backbone| LAW
    AA -->|Azure Backbone| SA
    AA -->|Azure Backbone| KV
    
    GRAPH_API -.->|SMTP/HTTPS| ADMINS
    
    classDef azure fill:#0078d4,stroke:#ffffff,stroke-width:2px,color:#ffffff
    classDef external fill:#ff6b35,stroke:#ffffff,stroke-width:2px,color:#ffffff
    classDef secure fill:#28a745,stroke:#ffffff,stroke-width:2px,color:#ffffff
    
    class AA,LAW,SA,KV,SUB1,SUB2,SUBN,COST_API,GRAPH_API azure
    class ANTHROPIC external
    class ADMINS secure
```

## Security Architecture

```mermaid
graph TB
    subgraph "Identity & Access Management"
        MI[System Managed Identity]
        RBAC[RBAC Assignments]
        
        subgraph "Assigned Roles"
            CMR[Cost Management Reader]
            READER[Reader]
            BR[Billing Reader] 
            LAC[Log Analytics Contributor]
        end
        
        MI --> CMR
        MI --> READER
        MI --> BR
        MI --> LAC
    end
    
    subgraph "Secret Management"
        KV_SEC[Key Vault]
        AUTO_VAR[Automation Variables]
        
        subgraph "Stored Secrets"
            ANTHROPIC_KEY[Anthropic API Key]
            EMAIL_SECRET[Email Client Secret]
            EMAIL_CONFIG[Email Configuration]
        end
        
        KV_SEC --> ANTHROPIC_KEY
        AUTO_VAR --> EMAIL_SECRET
        AUTO_VAR --> EMAIL_CONFIG
    end
    
    subgraph "Network Security"
        HTTPS[HTTPS/TLS Encryption]
        BACKBONE[Azure Backbone Network]
        
        subgraph "Traffic Types"
            INTERNAL[Azure-to-Azure]
            EXTERNAL[External API Calls]
        end
        
        BACKBONE --> INTERNAL
        HTTPS --> EXTERNAL
    end
    
    subgraph "Data Protection"
        ENCRYPT[Encryption at Rest]
        RETENTION[Data Retention Policies]
        
        subgraph "Retention Periods"
            COST_RET[Cost Data: 365 days]
            LOG_RET[Operational Logs: 30 days]
            PERF_RET[Performance Data: 90 days]
        end
        
        RETENTION --> COST_RET
        RETENTION --> LOG_RET
        RETENTION --> PERF_RET
    end
    
    classDef security fill:#dc3545,stroke:#ffffff,stroke-width:2px,color:#ffffff
    classDef config fill:#ffc107,stroke:#000000,stroke-width:2px,color:#000000
    classDef data fill:#28a745,stroke:#ffffff,stroke-width:2px,color:#ffffff
    
    class MI,RBAC,CMR,READER,BR,LAC security
    class KV_SEC,AUTO_VAR,ANTHROPIC_KEY,EMAIL_SECRET,EMAIL_CONFIG config
    class ENCRYPT,RETENTION,COST_RET,LOG_RET,PERF_RET data
```

## Deployment Architecture

```mermaid
graph TB
    subgraph "Development Environment"
        DEV_TERRAFORM[Terraform Configuration]
        DEV_SCRIPTS[PowerShell Scripts]
        DEV_CONFIG[terraform.tfvars]
    end
    
    subgraph "CI/CD Pipeline (Future)"
        GIT[Git Repository]
        VALIDATE[Terraform Validate]
        PLAN[Terraform Plan]
        APPLY[Terraform Apply]
    end
    
    subgraph "Azure Deployment"
        RG[Resource Group]
        
        subgraph "Infrastructure Resources"
            INF_AA[Automation Account]
            INF_LAW[Log Analytics]
            INF_SA[Storage Account]
            INF_KV[Key Vault]
            INF_DCR[Data Collection Rules]
        end
        
        subgraph "Configuration Resources"
            RUNBOOKS[PowerShell Runbooks]
            SCHEDULES[Automation Schedules]
            VARIABLES[Automation Variables]
            RBAC_ASSIGN[RBAC Assignments]
        end
    end
    
    subgraph "Operational Validation"
        TEST_COLLECT[Test Cost Collection]
        TEST_ANALYSIS[Test Weekly Analysis]
        TEST_EMAIL[Test Email Delivery]
        MONITOR[Setup Monitoring]
    end
    
    DEV_TERRAFORM --> VALIDATE
    DEV_SCRIPTS --> VALIDATE
    DEV_CONFIG --> VALIDATE
    
    VALIDATE --> PLAN
    PLAN --> APPLY
    
    APPLY --> RG
    RG --> INF_AA
    RG --> INF_LAW
    RG --> INF_SA
    RG --> INF_KV
    RG --> INF_DCR
    
    INF_AA --> RUNBOOKS
    INF_AA --> SCHEDULES
    INF_AA --> VARIABLES
    INF_AA --> RBAC_ASSIGN
    
    RUNBOOKS --> TEST_COLLECT
    SCHEDULES --> TEST_ANALYSIS
    VARIABLES --> TEST_EMAIL
    RBAC_ASSIGN --> MONITOR
    
    classDef dev fill:#17a2b8,stroke:#ffffff,stroke-width:2px,color:#ffffff
    classDef cicd fill:#6f42c1,stroke:#ffffff,stroke-width:2px,color:#ffffff
    classDef azure fill:#0078d4,stroke:#ffffff,stroke-width:2px,color:#ffffff
    classDef test fill:#28a745,stroke:#ffffff,stroke-width:2px,color:#ffffff
    
    class DEV_TERRAFORM,DEV_SCRIPTS,DEV_CONFIG dev
    class GIT,VALIDATE,PLAN,APPLY cicd
    class RG,INF_AA,INF_LAW,INF_SA,INF_KV,INF_DCR,RUNBOOKS,SCHEDULES,VARIABLES,RBAC_ASSIGN azure
    class TEST_COLLECT,TEST_ANALYSIS,TEST_EMAIL,MONITOR test
```
