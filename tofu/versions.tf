terraform {
  required_version = ">= 1.6.0"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "5.7.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "3.9.1"
    }
  }

  # Partial config: resource_group_name/storage_account_name/container_name/key are
  # supplied at `tofu init` time via -backend-config="key=value" flags, not a
  # committed/generated file (see README.md) - the same way CI supplies them, from
  # repository variables (see ../.github/workflows/tofu-*.yml). A remote backend is
  # required here, not optional - this state is applied unattended from CI on every
  # push to main, so it must be shared and locked across runs instead of living on a
  # single laptop.
  #
  # Auth is intentionally left unset here: locally it falls back to your `az login`
  # session; in CI, ARM_USE_OIDC/ARM_CLIENT_ID/ARM_TENANT_ID/ARM_SUBSCRIPTION_ID are
  # set as workflow env vars instead (see ../.github/workflows/), which both this
  # backend and the provider below pick up the same way.
  #
  # use_azuread_auth: talk to the state blob via each caller's own Azure AD identity
  # (RBAC'd with Storage Blob Data Contributor on the tfstate storage account) instead
  # of a shared storage account key, so no key ever needs to be issued or stored.
  backend "azurerm" {
    use_azuread_auth = true
  }
}

provider "azurerm" {
  features {}
  resource_providers_to_register = [
    "Microsoft.Storage",
    "Microsoft.Web"
  ]
  subscription_id = var.subscription_id
}
