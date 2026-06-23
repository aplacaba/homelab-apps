resource "cloudflare_api_token" "cert_manager_watchtoken" {
  name = "cert-manager-watchtoken-org"
  policies = [
    {
      effect            = "allow"
      permission_groups = [{ id = "Zone Read" }, { id = "DNS Edit" }]
      resources = {
        "com.cloudflare.api.account.zone.${data.cloudflare_zone.watchtoken_org.zone_id}" = "*"
      }
    }
  ]
}

resource "cloudflare_api_token" "cert_manager_alacaba" {
  name = "cert-manager-alacaba-org"
  policies = [
    {
      effect            = "allow"
      permission_groups = [{ id = "Zone Read" }, { id = "DNS Edit" }]
      resources = {
        "com.cloudflare.api.account.zone.${data.cloudflare_zone.alacaba_org.zone_id}" = "*"
      }
    }
  ]
}
