# The very first apply of this config MUST run with local state: it's what creates
# the storage account, so it can't already be reading/writing through it (a config
# can't be the backend for the thing that creates its own backend). After that first
# apply, though, the account exists - migrate this config's state into it too with
# `-backend-config="key=value"` flags and `-migrate-state` (see bootstrap/README.md).
# It's still small, rarely-changed, foundational infra, run by hand, not from CI, but
# there's no reason for it to keep living only on one person's laptop once it can move.
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

  backend "azurerm" {
    use_azuread_auth = true
  }
}

provider "azurerm" {
  features {
  }
  subscription_id = var.subscription_id
  resource_providers_to_register = [
    "Microsoft.Storage",
    "Microsoft.ManagedIdentity"
  ]

  storage_use_azuread = true
}

data "azurerm_client_config" "current" {}
