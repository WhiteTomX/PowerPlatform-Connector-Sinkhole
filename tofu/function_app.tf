# Consumption ("Y1") plan: billed per-execution/GB-s with a substantial monthly free
# grant, $0 while idle, and shared by every Function App below regardless of domain count.
resource "azurerm_service_plan" "consumption" {
  name                = "asp-ppcs"
  resource_group_name = data.azurerm_resource_group.main.name
  location            = data.azurerm_resource_group.main.location
  os_type             = "Linux"
  sku_name            = "Y1"
}


# One Linux Consumption Function App per tracked domain, named after the domain's
# label (e.g. "cc-bot-master-server") so its default hostname IS
# "<label>.azurewebsites.net" - claiming that name is what reclaims the dangling
# domain. Adding/removing an entry in var.domains_file and re-applying
# adds/removes the matching app here.
resource "azurerm_linux_function_app" "catcher" {
  for_each = local.domain_labels

  name                = each.key
  resource_group_name = data.azurerm_resource_group.main.name
  location            = data.azurerm_resource_group.main.location
  service_plan_id     = azurerm_service_plan.consumption.id

  storage_account_name       = azurerm_storage_account.dumps.name
  storage_account_access_key = azurerm_storage_account.dumps.primary_access_key

  # No Application Insights connection configured anywhere in this app - keeps the
  # only copy of captured request content in the blob written by dump.js, never in
  # a telemetry/log pipeline.
  site_config {
    application_stack {
      node_version = "20"
    }
  }

  app_settings = {
    FUNCTIONS_WORKER_RUNTIME = "node"
    DOMAIN_LABEL             = each.key
  }

  tags = {
    purpose = "ppcs-sinkhole"
    domain  = each.value
  }
}

# Deploys the catch-all POST/PUT dump function's source directly via the AzureRM
# provider (no build/zip pipeline) - identical for every app, driven purely by the
# %DOMAIN_LABEL% app setting each app already carries.
resource "azurerm_function_app_function" "dump" {
  for_each = local.domain_labels

  name            = "dump"
  function_app_id = azurerm_linux_function_app.catcher[each.key].id
  language        = "Javascript"

  file {
    name    = "index.js"
    content = file("${path.module}/${var.function_source_path}")
  }

  config_json = jsonencode({
    bindings = [
      {
        authLevel = "anonymous"
        type      = "httpTrigger"
        direction = "in"
        name      = "req"
        methods   = ["post", "put"]
        route     = "{*rest}"
      },
      {
        type      = "http"
        direction = "out"
        name      = "res"
      },
      {
        type       = "blob"
        direction  = "out"
        name       = "outputBlob"
        path       = "dumps/%DOMAIN_LABEL%/{rand-guid}.raw"
        connection = "AzureWebJobsStorage"
      }
    ]
  })
}
