output "reclaimed_domains" {
  description = "Map of domain label -> the azurewebsites.net hostname now reserved by a Function App."
  value = {
    for label, app in azurerm_function_app_flex_consumption.catcher :
    label => app.default_hostname
  }
}

output "storage_account_name" {
  description = "Storage account holding the 'dumps' container. Use with `az storage blob list/download/delete --account-name <this> -c dumps --auth-mode login` to review and clear captured requests."
  value       = azurerm_storage_account.dumps.name
}

output "resource_group_name" {
  value = data.azurerm_resource_group.main.name
}
