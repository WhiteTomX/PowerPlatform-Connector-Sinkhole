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

# Shared by every Function App below (both as their runtime/trigger storage and as
# the destination for dumped requests). Sharing one Standard LRS account across many
# low-volume Consumption-plan apps keeps this at pennies/month instead of one account
# per domain.
resource "azurerm_storage_account" "dumps" {
  name                     = "stppcsdumps${random_string.storage_suffix.result}"
  resource_group_name      = data.azurerm_resource_group.main.name
  location                 = data.azurerm_resource_group.main.location
  account_tier             = "Standard"
  account_replication_type = "LRS"
  min_tls_version          = "TLS1_2"

  # No static website / public blob access - dumps are only ever read via
  # authenticated `az storage blob` calls (see README) for triage, never served back out.
  allow_nested_items_to_be_public = false
}

# Each captured POST/PUT lands as one blob here at "<domain-label>/<rand-guid>.raw"
# containing the raw method/url/headers/body - nothing is parsed or forwarded into
# a logging/observability pipeline, so review happens by listing/downloading blobs.
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

# Consumption ("Y1") plan: billed per-execution/GB-s with a substantial monthly free
# grant, $0 while idle, and shared by every Function App below regardless of domain count.
resource "azurerm_service_plan" "consumption" {
  name                = "asp-ppcs"
  resource_group_name = data.azurerm_resource_group.main.name
  location            = data.azurerm_resource_group.main.location
  os_type             = "Linux"
  sku_name            = "Y1"
}
