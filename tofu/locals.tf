locals {
  # The tracking file is a flat JSON array of { domain, dateAdded, connectors,
  # nameAvailable, nameAvailabilityReason, nameCheckedDate } - the nameAvailable fields
  # are stamped by Update-DanglingConnectorDomain.ps1 from a live Azure
  # checkNameAvailability check (true also covers a name this same config already
  # claimed - see that script's Get-ClaimedFunctionAppNames).
  tracked_domains = jsondecode(file("${path.module}/${var.domains_file}"))

  # Only claim domains the last availability check found claimable - excludes ones
  # currently unclaimable (already held by someone/something else, e.g. mid Azure's
  # post-delete name-retention window) so one unavailable name doesn't fail the whole
  # apply. try() also excludes entries that predate this field entirely (missing it
  # altogether) - those are simply not yet verified, not necessarily unavailable.
  available_domains = [
    for entry in local.tracked_domains :
    entry if try(entry.nameAvailable, false) == true
  ]

  # We only need the domain label (the subdomain part before ".azurewebsites.net"),
  # since that label IS the Function App name and reserving that name is what
  # reclaims "<label>.azurewebsites.net" and stops it being takeover-able.
  domain_labels = {
    for entry in local.available_domains :
    trimsuffix(entry.domain, ".azurewebsites.net") => entry.domain
  }
}
