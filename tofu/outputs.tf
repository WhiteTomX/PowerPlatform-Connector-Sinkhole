output "reclaimed_domains" {
  description = "Map of domain label -> the azurewebsites.net hostname now reserved by a Function App."
  value = {
    for label, app in azurerm_function_app_flex_consumption.catcher :
    label => app.default_hostname
  }
}

output "storage_account_name" {
  description = "Storage account holding the 'dumps' container. Use with `az storage blob list/download/delete --account-name <this> -c dumps --auth-mode login` to review and clear captured requests."
  value       = azurerm_storage_account.functions.name
}

output "resource_group_name" {
  value = data.azurerm_resource_group.main.name
}

output "skipped_unavailable_domains" {
  description = "Tracked domains excluded from this apply because their last Azure name-availability check (or the absence of one) found them not currently claimable - see UnregisteredAzureWebsitesDomains.json's nameAvailabilityReason/nameCheckedDate for each."
  value = [
    for entry in local.tracked_domains :
    entry.domain if try(entry.nameAvailable, false) != true
  ]
}
