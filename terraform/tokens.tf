locals {
  permission_groups = [
    { id = "c8fed203ed3043cba015a93ad1616f1f" }, # Zone Read
    { id = "4755a26eedb94da69e1066d98aa820be" }, # DNS Write
  ]
}

resource "cloudflare_api_token" "cert_manager_watchtoken" {
  name = "cert-manager-watchtoken-org"
  policies = [
    {
      effect            = "allow"
      permission_groups = local.permission_groups
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
      permission_groups = local.permission_groups
      resources = jsonencode({
        "com.cloudflare.api.account.zone.${data.cloudflare_zone.alacaba_org.zone_id}" = "*"
      })
    }
  ]
}
