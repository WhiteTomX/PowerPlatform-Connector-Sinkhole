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

resource "azurerm_federated_identity_credential" "discover_domains" {
  name                      = "gh-discover-domains"
  user_assigned_identity_id = azurerm_user_assigned_identity.github_actions_plan.id
  audience                  = ["api://AzureADTokenExchange"]
  issuer                    = "https://token.actions.githubusercontent.com"
  subject                   = "repo:${var.github_repository}:ref:refs/heads/${var.github_default_branch}"
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
  for_each = {
    "Website Contributor"         = "Required to create functions",
    "Web Plan Contributor"        = "Required to create Service Plan"
    "Storage Account Contributor" = "Create Storage for dumps"
    # Data-plane role: Contributor above is ARM/management-plane only and can't
    # create containers or upload the deployment package blob once the functions
    # account has shared_access_key_enabled = false (see storage_use_azuread in
    # tofu/versions.tf).
    "Storage Blob Data Contributor" = "Create dumps/deployment-package containers and upload the function's deployment zip"
  }
  scope                = azurerm_resource_group.workload.id
  role_definition_name = each.key
  principal_id         = azurerm_user_assigned_identity.github_actions_apply.principal_id
}

# Storage Blob Data Owner - the only role `apply` is ever allowed to delegate via the
# constrained User Access Administrator grant below. Flex Consumption's own samples
# use this (not just Contributor) for a Function App's identity-based storage access.
# Stable built-in GUID, same across every Azure tenant/subscription.
locals {
  storage_blob_data_owner_role_id = "b7e6dc6d-f1e8-4753-8033-0f276bb0955b"
}

# Contributor roles deliberately exclude Microsoft.Authorization/roleAssignments/write,
# but `apply` needs to grant each catcher Function App's managed identity blob access
# to the functions storage account (its only access, since that account has
# shared_access_key_enabled = false). Plain User Access Administrator would let a
# compromised `apply` identity grant ANY role - including Owner - to ANY principal in
# the workload RG, i.e. full privilege escalation. The condition below constrains it
# to assigning (and revoking) only Storage Blob Data Owner, no matter the target
# principal or resource.
resource "azurerm_role_assignment" "github_actions_apply_workload_uaa" {
  scope                = azurerm_resource_group.workload.id
  role_definition_name = "User Access Administrator"
  principal_id         = azurerm_user_assigned_identity.github_actions_apply.principal_id
  condition_version    = "2.0"
  condition            = <<-COND
    (
      (
        !(ActionMatches{'Microsoft.Authorization/roleAssignments/write'})
      )
      OR
      (
        @Request[Microsoft.Authorization/roleAssignments:RoleDefinitionId] {ForAnyOfAnyValues:GuidEquals} {${local.storage_blob_data_owner_role_id}}
      )
    )
    AND
    (
      (
        !(ActionMatches{'Microsoft.Authorization/roleAssignments/delete'})
      )
      OR
      (
        @Resource[Microsoft.Authorization/roleAssignments:RoleDefinitionId] {ForAnyOfAnyValues:GuidEquals} {${local.storage_blob_data_owner_role_id}}
      )
    )
  COND
}

resource "azurerm_role_assignment" "github_actions_apply_tfstate_blob" {
  scope                = azurerm_storage_account.tfstate.id
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = azurerm_user_assigned_identity.github_actions_apply.principal_id
}
