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
    archive = {
      source  = "hashicorp/archive"
      version = "2.7.1"
    }
  }

  backend "azurerm" {
    use_azuread_auth = true
  }
}

provider "azurerm" {
  features {}
  # The plan probably doesnt have the permission to register providers, but tries to
  # register manually
  resource_providers_to_register = [
    "Microsoft.Storage",
    "Microsoft.Web"
  ]
  subscription_id = var.subscription_id

  # The dumps storage account has shared_access_key_enabled = false, so container/blob
  # management here (creating the dumps/deployment-package containers, uploading the
  # deployment zip) must authenticate as the caller's own Entra ID identity instead of
  # a storage account key.
  storage_use_azuread = true
}
