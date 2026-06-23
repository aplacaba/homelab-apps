data "cloudflare_api_token_permission_groups_list" "all" {}

locals {
  zone_read_id = one([
    for g in data.cloudflare_api_token_permission_groups_list.all.result : g.id
    if g.name == "Zone Read"
  ])
  dns_edit_id = one([
    for g in data.cloudflare_api_token_permission_groups_list.all.result : g.id
    if g.name == "DNS Edit"
  ])
}

resource "cloudflare_api_token" "cert_manager_watchtoken" {
  name = "cert-manager-watchtoken-org"
  policies = [
    {
      effect            = "allow"
      permission_groups = [{ id = local.zone_read_id }, { id = local.dns_edit_id }]
      resources = jsonencode({
        "com.cloudflare.api.account.zone.${data.cloudflare_zone.watchtoken_org.zone_id}" = "*"
      })
    }
  ]
}

resource "cloudflare_api_token" "cert_manager_alacaba" {
  name = "cert-manager-alacaba-org"
  policies = [
    {
      effect            = "allow"
      permission_groups = [{ id = local.zone_read_id }, { id = local.dns_edit_id }]
      resources = jsonencode({
        "com.cloudflare.api.account.zone.${data.cloudflare_zone.alacaba_org.zone_id}" = "*"
      })
    }
  ]
}
