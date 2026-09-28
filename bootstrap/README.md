# bootstrap

One-time setup, run by hand, logged in as an account that can create resource
groups / storage accounts / role assignments / app registrations. It creates
the things the main `../tofu` config's remote backend and CI identity depend
on, so it can't depend on either of those itself:

- the tfstate resource group + storage account + container (AAD-only, no storage keys - `shared_access_key_enabled = false`)
- the workload resource group (`data.azurerm_resource_group.main` in `../tofu/storage.tf` just reads this)
- two user-assigned managed identities for GitHub Actions, each with a federated credential trusting this repo's OIDC tokens for one workflow:
  - `id-github-actions-ppcs-plan`, for `tofu-plan.yml` (pull_request trigger) - read-only: `Reader` on the workload resource group, `Storage Blob Data Reader` on the tfstate account
  - `id-github-actions-ppcs-apply`, for `deploy.yml` (`environment: production` trigger) - read-write: `Contributor` on the workload resource group, `Storage Blob Data Contributor` on the tfstate account

If `var.github_repository` or `var.workload_resource_group_name` in
`variables.tf` don't match your actual repo / desired resource group name,
override them (`-var`/`terraform.tfvars`) before applying.

## First apply: local state

The storage account this config creates doesn't exist yet, so it can't also be
this config's own backend yet - `tofu init` with no backend configured falls
back to local state. So first comment out the `backend` block from `versions.tf`. Then run

```bash
cd bootstrap
tofu init
tofu apply
resource_group_name=$(tofu output -raw tfstate_resource_group_name)
storage_account_name=$(tofu output -raw tfstate_storage_account_name)
container_name=$(tofu output -raw tfstate_container_name)
key=$(tofu output -raw bootstrap_tfstate_key)
```

afterwards uncomment and run

```bash
tofu init \
  -backend-config="resource_group_name=$resource_group_name" \
  -backend-config="storage_account_name=$storage_account_name" \
  -backend-config="container_name=$container_name" \
  -backend-config="key=$key" \
  -migrate-state
```

Confirm `yes` when prompted to copy the local state into the storage account.
From then on, the same `-backend-config` flags (without `-migrate-state`) are all
that's needed here, and `bootstrap/terraform.tfstate` can be deleted locally once
you've verified the remote state is intact.

## Wire up CI

See the main `../README.md` for the required GitHub repository secrets
and what each `bootstrap` output feeds into.
