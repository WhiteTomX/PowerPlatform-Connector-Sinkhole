locals {
  # The tracking file is a flat JSON array of { domain, dateAdded, connectors }.
  # We only need the domain label (the subdomain part before ".azurewebsites.net"),
  # since that label IS the Function App name and reserving that name is what
  # reclaims "<label>.azurewebsites.net" and stops it being takeover-able.
  tracked_domains = jsondecode(file("${path.module}/${var.domains_file}"))

  domain_labels = {
    for entry in local.tracked_domains :
    trimsuffix(entry.domain, ".azurewebsites.net") => entry.domain
  }
}
