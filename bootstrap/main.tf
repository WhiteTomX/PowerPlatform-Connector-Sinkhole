resource "azurerm_resource_group" "tfstate" {
  name     = var.tfstate_resource_group_name
  location = var.location
}

# The workload resource group itself - created here (not by the main config) so that
# a role assignment scoped to it can exist before the main config's first apply. The
# main config only ever reads this group via a data source.
resource "azurerm_resource_group" "workload" {
  name     = var.workload_resource_group_name
  location = var.location
}

resource "random_string" "tfstate_suffix" {
  length  = 8
  special = false
  upper   = false
}

resource "azurerm_storage_account" "tfstate" {
  name                     = "stppcstfstate${random_string.tfstate_suffix.result}"
  resource_group_name      = azurerm_resource_group.tfstate.name
  location                 = azurerm_resource_group.tfstate.location
  account_tier             = "Standard"
  account_replication_type = "LRS"

  allow_nested_items_to_be_public = false
  shared_access_key_enabled       = false
}

# Whoever runs this bootstrap (a user via `az login`, or a pipeline identity) needs
# Storage Blob Data Contributor on the account to migrate bootstrap backend
resource "azurerm_role_assignment" "bootstrap_caller_tfstate_blob" {
  scope                = azurerm_storage_account.tfstate.id
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = data.azurerm_client_config.current.object_id
}

resource "azurerm_storage_container" "tfstate" {
  name                  = var.tfstate_container_name
  storage_account_id    = azurerm_storage_account.tfstate.id
  container_access_type = "private"
}

resource "azurerm_user_assigned_identity" "github_actions_plan" {
  name                = "id-github-actions-ppcs-plan"
  resource_group_name = azurerm_resource_group.tfstate.name
  location            = azurerm_resource_group.tfstate.location
}

resource "azurerm_user_assigned_identity" "github_actions_apply" {
  name                = "id-github-actions-ppcs-apply"
  resource_group_name = azurerm_resource_group.tfstate.name
  location            = azurerm_resource_group.tfstate.location
}

# tofu-plan.yml: pull_request trigger, no `environment:` set on the job - GitHub's
# OIDC subject for that is "repo:<owner>/<repo>:pull_request".
resource "azurerm_federated_identity_credential" "pull_request" {
  name                      = "gh-pull-request"
  user_assigned_identity_id = azurerm_user_assigned_identity.github_actions_plan.id
  audience                  = ["api://AzureADTokenExchange"]
  issuer                    = "https://token.actions.githubusercontent.com"
  subject                   = "repo:${var.github_repository}:pull_request"
}


resource "azurerm_federated_identity_credential" "production_environment" {
  name                      = "gh-environment-${var.github_environment}"
  user_assigned_identity_id = azurerm_user_assigned_identity.github_actions_apply.id
  audience                  = ["api://AzureADTokenExchange"]
  issuer                    = "https://token.actions.githubusercontent.com"
  subject                   = "repo:${var.github_repository}:environment:${var.github_environment}"
}

resource "azurerm_role_assignment" "github_actions_plan_workload_reader" {
  scope                = azurerm_resource_group.workload.id
  role_definition_name = "Reader"
  principal_id         = azurerm_user_assigned_identity.github_actions_plan.principal_id
}

resource "azurerm_role_assignment" "github_actions_plan_tfstate_blob" {
  scope                = azurerm_storage_account.tfstate.id
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = azurerm_user_assigned_identity.github_actions_plan.principal_id
}


resource "azurerm_role_assignment" "github_actions_apply_workload_contributor" {
  scope                = azurerm_resource_group.workload.id
  role_definition_name = "Website Contributor"
  principal_id         = azurerm_user_assigned_identity.github_actions_apply.principal_id
}

resource "azurerm_role_assignment" "github_actions_apply_tfstate_blob" {
  scope                = azurerm_storage_account.tfstate.id
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = azurerm_user_assigned_identity.github_actions_apply.principal_id
}
