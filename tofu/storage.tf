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

# Shared by every Function App below - as their Flex Consumption host storage
# (AzureWebJobsStorage) AND as the destination for dumped requests, both accessed
# purely via each app's system-assigned identity. Shared key access is disabled, so
# the only way to read/write anything here is Entra ID + RBAC (the catcher apps'
# identities, or `az ... --auth-mode login` for a human reviewing captures) - never a
# copyable connection string/key. Flex Consumption (unlike the old Y1 plan) supports
# identity-based access for host storage and deployment packages by default, so one
# account can safely cover everything.
resource "azurerm_storage_account" "functions" {
  name                     = "stppcsfunc${random_string.storage_suffix.result}"
  resource_group_name      = data.azurerm_resource_group.main.name
  location                 = data.azurerm_resource_group.main.location
  account_tier             = "Standard"
  account_replication_type = "LRS"
  min_tls_version          = "TLS1_2"

  allow_nested_items_to_be_public = false
  shared_access_key_enabled       = false
}

resource "azurerm_storage_container" "dumps" {
  name                  = "dumps"
  storage_account_id    = azurerm_storage_account.functions.id
  container_access_type = "private"
}

# Holds the zipped function code package every catcher app runs from - identical
# across all of them, so one shared container/blob is enough. Terraform only
# declares the container; the deploy workflow's deploy step is what actually
# pushes a package into it and activates it (Flex Consumption only recognizes a
# package pushed through a real deployment call - a blob dropped into this
# container directly never gets picked up, see functions-deployment-technologies).
resource "azurerm_storage_container" "deployment_package" {
  name                  = "deployment-package"
  storage_account_id    = azurerm_storage_account.functions.id
  container_access_type = "private"
}

resource "azurerm_storage_management_policy" "dumps_expiry" {
  count              = var.dump_retention_days > 0 ? 1 : 0
  storage_account_id = azurerm_storage_account.functions.id

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
