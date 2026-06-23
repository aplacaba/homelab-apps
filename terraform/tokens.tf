resource "cloudflare_api_token" "cert_manager_watchtoken" {
  name = "cert-manager-watchtoken-org"
  policy {
    permission_groups = ["Zone Read", "DNS Edit"]
    resources = {
      "com.cloudflare.api.account.zone.${data.cloudflare_zone.watchtoken_org.id}" = "*"
    }
  }
}

resource "cloudflare_api_token" "cert_manager_alacaba" {
  name = "cert-manager-alacaba-org"
  policy {
    permission_groups = ["Zone Read", "DNS Edit"]
    resources = {
      "com.cloudflare.api.account.zone.${data.cloudflare_zone.alacaba_org.id}" = "*"
    }
  }
}
