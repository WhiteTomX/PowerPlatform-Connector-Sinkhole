variable "subscription_id" {
  description = "Azure subscription ID to deploy into. Leave null to use the az CLI's current subscription."
  type        = string
  default     = null
}

variable "location" {
  description = "Azure region for all resources."
  type        = string
  default     = "germanywestcentral"
}

variable "github_repository" {
  description = "GitHub \"owner/repo\" this identity's federated credentials trust. Must match exactly - it's embedded in the OIDC subject claim GitHub presents. Make sure to include owner_id and repo_id for new repos."
  type        = string
  default     = "WhiteTomX@38078578/PowerPlatform-Connector-Sinkhole@1390709213"
}

variable "github_environment" {
  description = "GitHub Environment name used by the tofu-apply job (.github/workflows/tofu-apply.yml sets `environment:` on that job, which changes its OIDC subject claim to this environment rather than the branch ref)."
  type        = string
  default     = "production"
}

variable "tfstate_resource_group_name" {
  description = "Resource group to hold the Terraform/OpenTofu remote state storage account."
  type        = string
  default     = "rg-ppcs-tfstate"
}

variable "tfstate_container_name" {
  type    = string
  default = "tfstate"
}

variable "tfstate_key" {
  type    = string
  default = "ppcs.tfstate"
}

variable "bootstrap_tfstate_key" {
  description = "Blob key for this bootstrap config's own state, once migrated into the storage account it creates (see README.md). Distinct from tfstate_key, which is the main ../tofu config's key - both live in the same container."
  type        = string
  default     = "bootstrap.tfstate"
}

variable "workload_resource_group_name" {
  description = "Resource group the main config (../tofu) deploys the catcher Function Apps into. Must match that config's `resource_group_name` variable exactly - this module creates the group, the main config only reads it."
  type        = string
  default     = "rg-ppcs"
}
