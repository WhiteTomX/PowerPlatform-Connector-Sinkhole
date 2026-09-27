# Created by terraform/bootstrap (which also creates the CI managed identity that is
# granted Contributor on it) - referenced here as data so its lifecycle isn't tied to
# this config's day-to-day plan/apply cycle.
data "azurerm_resource_group" "main" {
  name = var.resource_group_name
}

resource "random_string" "storage_suffix" {
  length  = 8
  special = false
  upper   = false
}

# Holds only the captured request dumps - the sensitive payload of this whole project.
# Shared key access is disabled so the only way to read/write it is Entra ID + RBAC
# (the catcher Function Apps' managed identities, or `az ... --auth-mode login` for a
# human reviewing captures), never a copyable connection string/key.
resource "azurerm_storage_account" "dumps" {
  name                     = "stppcsdumps${random_string.storage_suffix.result}"
  resource_group_name      = data.azurerm_resource_group.main.name
  location                 = data.azurerm_resource_group.main.location
  account_tier             = "Standard"
  account_replication_type = "LRS"
  min_tls_version          = "TLS1_2"

  allow_nested_items_to_be_public = false
  shared_access_key_enabled       = false
}

# The Y1 Consumption plan's host storage (AzureWebJobsStorage - scale controller
# bookkeeping, run-from-package deployment) doesn't reliably support identity-based
# access, so it stays key-based and separate from the dumps account. It never holds
# captured request content.
resource "azurerm_storage_account" "runtime" {
  name                     = "stppcsrun${random_string.storage_suffix.result}"
  resource_group_name      = data.azurerm_resource_group.main.name
  location                 = data.azurerm_resource_group.main.location
  account_tier             = "Standard"
  account_replication_type = "LRS"
  min_tls_version          = "TLS1_2"

  allow_nested_items_to_be_public = false
}

resource "azurerm_storage_container" "dumps" {
  name                  = "dumps"
  storage_account_id    = azurerm_storage_account.dumps.id
  container_access_type = "private"
}

resource "azurerm_storage_management_policy" "dumps_expiry" {
  count              = var.dump_retention_days > 0 ? 1 : 0
  storage_account_id = azurerm_storage_account.dumps.id

  rule {
    name    = "expire-dumps"
    enabled = true

    filters {
      prefix_match = ["dumps/"]
      blob_types   = ["blockBlob"]
    }

    actions {
      base_blob {
        delete_after_days_since_modification_greater_than = var.dump_retention_days
      }
    }
  }
}
