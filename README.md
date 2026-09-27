# PowerPlatform Connector Sinkhole (ppcs)

Sinkholes dangling `*.azurewebsites.net` domains referenced by Microsoft Power
Platform connectors (from
[microsoft/PowerPlatformConnectors](https://github.com/microsoft/PowerPlatformConnectors))
to block takeover.

`Update-DanglingConnectorDomain.ps1` scans that repo for every connector's
declared API host and checks which ones no longer resolve. Every dangling
`*.azurewebsites.net` host it finds gets tracked in
`UnregisteredAzureWebsitesDomains.json`, which `tofu/` then turns into
infrastructure: one Azure Function App per tracked domain, named after the
domain's label (a Function App's default hostname is always
`<name>.azurewebsites.net`, so creating the app *is* the claim). Each app
accepts any POST/PUT at any path, writes the raw request (method, URL, headers,
body) as a blob, and responds `410 Gone` with a notice that the domain is
dangling/reclaimed - nothing is parsed, indexed, or sent to a logging/telemetry
pipeline.

The domain list is the sole input to `tofu/`: add/remove an entry in the JSON
file and re-apply to add/remove the matching Function App.

## Layout

- `Update-DanglingConnectorDomain.ps1` / `.Tests.ps1` - the scanner and its Pester unit tests
- `UnregisteredAzureWebsitesDomains.json` - tracked dangling domains (the infra input)
- `src/` - the catch-all dump function's source, deployed identically into every Function App
- `tofu/` - the main OpenTofu config (Function Apps, storage, dump-retention policy)
- `bootstrap/` - one-time setup: state backend + CI identity (see below)
- `.github/workflows/` - automation tying it all together (see below)

## Cost

Everything runs on the Consumption plan (`Y1`), billed per-execution/GB-s with a large
monthly free grant shared across all apps - effectively $0/month at dangling-domain
traffic volumes. The only always-on cost is the Standard LRS storage account
(pennies/month for this volume of blobs).

## Tests

```pwsh
Invoke-Pester ./Update-DanglingConnectorDomain.Tests.ps1
```

Covers the pure/file-only helper functions (host extraction, apex-domain
reduction, tracking-file diffing) by dot-sourcing the script. The clone/DNS/CSV
parts aren't unit-tested - they need a live checkout and/or network access; run
the script itself to exercise those.

## Prerequisites

- [OpenTofu](https://opentofu.org/) >= 1.6
- Azure CLI, logged in (`az login`) with a subscription that can create resource
  groups / storage accounts / Function Apps
- The remote state backend bootstrapped once (see below) - this config is applied
  unattended from CI, so its state cannot live only on one person's laptop.

## First-time setup: bootstrap

`bootstrap/` is a separate, small OpenTofu config that creates the things the
main config's own remote backend and CI identity depend on, so it can't depend
on either of those itself. Run it once - see [`bootstrap/README.md`](bootstrap/README.md)
for the full procedure (its state starts local, then moves into the storage
account it creates). The GitHub repository secrets it feeds are listed
below.

## GitHub Actions

Three workflows automate the whole loop:

- **`discover-domains.yml`** (weekly + manual) - runs
  `Update-DanglingConnectorDomain.ps1`, uploads the full CSV as a build
  artifact, and opens a PR against `UnregisteredAzureWebsitesDomains.json` if new
  dangling domains showed up.
- **`tofu-plan.yml`** (on PRs touching `tofu/**` or the tracking JSON) - runs
  `tofu plan` and posts/updates a single PR comment with the result.
- **`tofu-apply.yml`** (on push to `main`) - runs `tofu apply -auto-approve`.

Required repository configuration (Settings -> Secrets and variables -> Actions).
Everything is a secret, even the non-sensitive tfstate backend coordinates - so
all CI configuration lives in one place (Actions secrets) instead of being
split across two tabs, and nothing about the backend's naming/layout is
exposed to anyone who can merely read the repo:

| Name | Type | Source / purpose |
| --- | --- | --- |
| `AZURE_CLIENT_ID_PLAN` | secret | `bootstrap` output `github_actions_plan_client_id` - read-only identity `tofu-plan.yml` authenticates as via OIDC |
| `AZURE_CLIENT_ID_APPLY` | secret | `bootstrap` output `github_actions_apply_client_id` - read-write identity `tofu-apply.yml` authenticates as via OIDC |
| `AZURE_TENANT_ID` | secret | `bootstrap` output `azure_tenant_id` |
| `AZURE_SUBSCRIPTION_ID` | secret | `bootstrap` output `azure_subscription_id` |
| `TFSTATE_RESOURCE_GROUP` | secret | `bootstrap` output `tfstate_resource_group_name` |
| `TFSTATE_STORAGE_ACCOUNT` | secret | `bootstrap` output `tfstate_storage_account_name` |
| `TFSTATE_CONTAINER` | secret | `bootstrap` output `tfstate_container_name` |
| `TFSTATE_KEY` | secret | `bootstrap` output `tfstate_key` |
| `INFRA_PR_TOKEN` | secret (optional) | A PAT/GitHub App token with `contents:write`+`pull-requests:write`. Without it, `discover-domains.yml` still opens its PR using the default token, but that PR will **not** auto-trigger `tofu-plan.yml` (GitHub blocks workflow-triggered-workflow runs from the default token) - re-run `tofu-plan` manually or push a commit to the PR instead. |

Both federated-credential subjects (pull_request, and `environment:production`) are
created by `bootstrap` already - nothing manual needed there beyond keeping
`var.github_environment` in sync with the `environment:` set on the `tofu-apply.yml`
job if you ever rename or remove it (see the comment on that federated credential in
`bootstrap/main.tf`).

Consider protecting the `production` GitHub Environment (used by `tofu-apply.yml`)
with required reviewers if you want a human gate before `main` pushes actually apply.

## Review and clear captured requests

```
STORAGE_ACCOUNT=$(tofu output -raw storage_account_name)

# List what's been captured for one domain
az storage blob list --account-name $STORAGE_ACCOUNT -c dumps --prefix "cc-bot-master-server/" --auth-mode login -o table

# Download one for inspection
az storage blob download --account-name $STORAGE_ACCOUNT -c dumps --name "cc-bot-master-server/<blob>.raw" --auth-mode login -f ./out.raw

# Delete everything under a domain once reviewed
az storage blob delete-batch --account-name $STORAGE_ACCOUNT -s dumps --pattern "cc-bot-master-server/*" --auth-mode login
```

## Roadmap

Currently captures stray POST/PUT traffic for analysis. Goal is to automatically inform the used account credentials automatically to avoid processing the content at all.

Furthermore I thought about creating PRs with the PowerPlatform Connectors Repo autoamtically to remove the connectors.
