variable "location" {
  description = "Azure region for deployment"
  type        = string
  default     = "eastus"
}

variable "project_name" {
  description = "Project identifier"
  type        = string
  default     = "nip-costing"
}

variable "environment" {
  description = "Environment name"
  type        = string
  default     = "dev"
}

variable "management_subscription_id" {
  description = "Management subscription ID"
  type        = string
  default     = "e653ba88-fc91-42f4-b22b-c35e36b00835"
}

variable "target_subscription_ids" {
  description = "List of subscription IDs for cost management"
  type        = list(string)
  default     = ["e653ba88-fc91-42f4-b22b-c35e36b00835"] # Start with single subscription for MVP
}

variable "cost_data_retention_days" {
  description = "Cost data retention in days"
  type        = number
  default     = 365 # 1 year for MVP (reduced from 7 years)
}

variable "log_retention_days" {
  description = "Log Analytics retention in days"
  type        = number
  default     = 30 # Reduced to minimum for cost savings - Cost data tables maintain 365-day retention automatically
}

variable "enable_extended_retention" {
  description = "Enable 90-day retention for operational data (doubles storage cost)"
  type        = bool
  default     = false # Set to true if you need more operational history for debugging
}

variable "location_abbreviation" {
  description = "Location abbreviation for naming"
  type        = string
  default     = "eus"
}

variable "project_owner" {
  description = "Project owner"
  type        = string
  default     = "DevOps Team"
}

variable "cost_center" {
  description = "Cost center"
  type        = string
  default     = "IT"
}

# Email configuration variables
variable "email_from_address" {
  description = "Email address to send reports from"
  type        = string
}

variable "email_client_id" {
  description = "Azure AD App Registration Client ID for email"
  type        = string
}

variable "email_tenant_id" {
  description = "Azure AD Tenant ID"
  type        = string
}

variable "email_client_secret" {
  description = "Azure AD App Registration Client Secret"
  type        = string
  sensitive   = true
}

# AI configuration
variable "anthropic_api_key" {
  description = "Anthropic API key for Claude"
  type        = string
  sensitive   = true
}

# Cost report configuration
variable "cost_report_recipients" {
  description = "Comma-separated list of email recipients for cost reports"
  type        = string
  default     = "costadmin@yourdomain.com"
}
