output "tfstate_resource_group_name" {
  value = azurerm_resource_group.tfstate.name
}

output "tfstate_storage_account_name" {
  value = azurerm_storage_account.tfstate.name
}

output "tfstate_container_name" {
  value = azurerm_storage_container.tfstate.name
}

output "tfstate_key" {
  value = var.tfstate_key
}

output "bootstrap_tfstate_key" {
  value = var.bootstrap_tfstate_key
}

output "workload_resource_group_name" {
  value = azurerm_resource_group.workload.name
}

output "github_actions_plan_client_id" {
  description = "-> repository secret AZURE_CLIENT_ID_PLAN"
  value       = azurerm_user_assigned_identity.github_actions_plan.client_id
}

output "github_actions_apply_client_id" {
  description = "-> repository secret AZURE_CLIENT_ID_APPLY"
  value       = azurerm_user_assigned_identity.github_actions_apply.client_id
}

output "azure_tenant_id" {
  description = "-> repository secret AZURE_TENANT_ID"
  value       = data.azurerm_client_config.current.tenant_id
}

output "azure_subscription_id" {
  description = "-> repository secret AZURE_SUBSCRIPTION_ID"
  value       = data.azurerm_client_config.current.subscription_id
}

