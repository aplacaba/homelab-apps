variable "zone_read_permission_group_id" {
  type        = string
  description = "Permission group UUID for 'Zone Read' (32-char hex from API)"
}

variable "dns_edit_permission_group_id" {
  type        = string
  description = "Permission group UUID for 'DNS Edit' (32-char hex from API)"
}

locals {
  permission_groups = [{ id = var.zone_read_permission_group_id }, { id = var.dns_edit_permission_group_id }]
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
