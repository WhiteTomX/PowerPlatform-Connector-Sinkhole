# Flex Consumption ("FC1"): billed per-execution/GB-s like the old Y1 Consumption
# plan, but (unlike Y1) supports identity-based access to its host/deployment storage
# by default - no shared key needed anywhere. Unlike Y1 (where every app shared one
# plan), Flex Consumption only allows one app per plan, so there's one of these per
# tracked domain too.
resource "azurerm_service_plan" "flex_consumption" {
  for_each = local.domain_labels

  name                = "asp-${each.key}"
  resource_group_name = data.azurerm_resource_group.main.name
  location            = data.azurerm_resource_group.main.location
  os_type             = "Linux"
  sku_name            = "FC1"
}

# One Flex Consumption Function App per tracked domain, named after the domain's
# label (e.g. "cc-bot-master-server") so its default hostname IS
# "<label>.azurewebsites.net" - claiming that name is what reclaims the dangling
# domain. Adding/removing an entry in var.domains_file and re-applying
# adds/removes the matching app here. All of them run off the one deployment
# package blob uploaded in deployment_package.tf, since the code is identical.
resource "azurerm_function_app_flex_consumption" "catcher" {
  for_each = local.domain_labels

  name                = each.key
  resource_group_name = data.azurerm_resource_group.main.name
  location            = data.azurerm_resource_group.main.location
  service_plan_id     = azurerm_service_plan.flex_consumption[each.key].id

  storage_container_type      = "blobContainer"
  storage_container_endpoint  = "${azurerm_storage_account.functions.primary_blob_endpoint}${azurerm_storage_container.deployment_package.name}"
  storage_authentication_type = "SystemAssignedIdentity"

  runtime_name    = "node"
  runtime_version = "22" # Flex Consumption doesn't support Node.js 20 - only 22 and 24

  # Each domain gets almost no real traffic (it's dangling), and dump.js does one
  # cheap JSON-stringify-and-write per request - one instance can serve concurrent
  # requests on its own, so there's no need to scale out at all. This also bounds
  # the bill if someone tries to hammer a reclaimed domain to run up costs.
  maximum_instance_count = 1
  instance_memory_in_mb  = 512

  identity {
    type = "SystemAssigned"
  }

  # No Application Insights connection configured anywhere in this app - keeps the
  # only copy of captured request content in the blob written by dump.js, never in
  # a telemetry/log pipeline.
  site_config {}

  app_settings = {
    DOMAIN_LABEL = each.key

    # Identity-based AzureWebJobsStorage (host storage, and the "connection" the
    # dumps output binding in src/dump/function.json refers to) - the app's
    # system-assigned identity authenticates via the role assignment below instead
    # of a shared key, since the functions account has none.
    AzureWebJobsStorage              = "" # workaround until https://github.com/hashicorp/terraform-provider-azurerm/pull/29099 is released
    AzureWebJobsStorage__accountName = azurerm_storage_account.functions.name
    dumps__blobServiceUri            = "https://${azurerm_storage_account.functions.name}.blob.core.windows.net"
  }

  tags = {
    purpose = "ppcs-sinkhole"
    domain  = each.value
  }
}

# Grants each catcher app's own identity access to the whole functions account - both
# to write into the dumps container and to read the shared deployment package blob,
# and to satisfy Flex Consumption's own host-storage bookkeeping. Storage Blob Data
# Owner (not just Contributor) is what Microsoft's samples use for Flex Consumption's
# identity-based storage access.
resource "azurerm_role_assignment" "catcher_dumps_blob" {
  for_each = local.domain_labels

  scope                = azurerm_storage_account.functions.id
  role_definition_name = "Storage Blob Data Owner"
  principal_id         = azurerm_function_app_flex_consumption.catcher[each.key].identity[0].principal_id
}
