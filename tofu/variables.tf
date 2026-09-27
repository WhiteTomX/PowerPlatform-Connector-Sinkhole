variable "subscription_id" {
  description = "Azure subscription ID to deploy into. Leave null to use the az CLI's current subscription / ARM_SUBSCRIPTION_ID env var."
  type        = string
  default     = null
}

variable "location" {
  description = "Azure region for all resources."
  type        = string
  default     = "westeurope"
}

variable "resource_group_name" {
  description = "Name of the resource group holding the PowerPlatform Connector Sinkhole (ppcs) infrastructure."
  type        = string
  default     = "rg-ppcs"
}

variable "domains_file" {
  description = "Path to the JSON file listing the dangling azurewebsites.net domains to reclaim. Adding/removing entries there and re-applying adds/removes the matching Function App."
  type        = string
  default     = "../UnregisteredAzureWebsitesDomains.json"
}

variable "function_source_path" {
  description = "Path to the catch-all dump function's source file, deployed identically into every Function App."
  type        = string
  default     = "../src/dump.js"
}

variable "dump_retention_days" {
  description = "Days to keep captured request dumps in blob storage before automatic deletion. Set to 0 to disable automatic expiry (not recommended - review and delete manually instead)."
  type        = number
  default     = 7
}
