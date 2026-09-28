resource "azurerm_log_analytics_workspace" "main" {
  name                = "log-ppcs"
  resource_group_name = data.azurerm_resource_group.main.name
  location            = data.azurerm_resource_group.main.location
  sku                 = "PerGB2018"
  retention_in_days   = 30

  # 0.023 is the lowest value Azure allows - minimizes the chance of ever
  # crossing the 5 GB/month free allowance.
  daily_quota_gb = 0.023
}

resource "azurerm_application_insights" "catcher" {
  name                = "appi-ppcs"
  resource_group_name = data.azurerm_resource_group.main.name
  location            = data.azurerm_resource_group.main.location
  workspace_id        = azurerm_log_analytics_workspace.main.id
  application_type    = "Node.JS"
}
