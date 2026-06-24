# ── watchtoken.org zone settings ──────────────────────────────────────────

resource "cloudflare_zone_setting" "watchtoken_always_use_https" {
  zone_id    = data.cloudflare_zone.watchtoken_org.id
  setting_id = "always_use_https"
  value      = "on"
}

resource "cloudflare_zone_setting" "watchtoken_hsts" {
  zone_id    = data.cloudflare_zone.watchtoken_org.id
  setting_id = "security_header"
  value = {
    strict_transport_security = {
      enabled            = true
      max_age            = 31536000
      include_subdomains = true
      preload            = true
    }
  }
}

resource "cloudflare_zone_setting" "watchtoken_ssl" {
  zone_id    = data.cloudflare_zone.watchtoken_org.id
  setting_id = "ssl"
  value      = "full"
}

resource "cloudflare_zone_setting" "watchtoken_browser_check" {
  zone_id    = data.cloudflare_zone.watchtoken_org.id
  setting_id = "browser_check"
  value      = "on"
}

# ── alacaba.org zone settings ─────────────────────────────────────────────

resource "cloudflare_zone_setting" "alacaba_always_use_https" {
  zone_id    = data.cloudflare_zone.alacaba_org.id
  setting_id = "always_use_https"
  value      = "on"
}

resource "cloudflare_zone_setting" "alacaba_hsts" {
  zone_id    = data.cloudflare_zone.alacaba_org.id
  setting_id = "security_header"
  value = {
    strict_transport_security = {
      enabled            = true
      max_age            = 31536000
      include_subdomains = true
      preload            = true
    }
  }
}

resource "cloudflare_zone_setting" "alacaba_ssl" {
  zone_id    = data.cloudflare_zone.alacaba_org.id
  setting_id = "ssl"
  value      = "full"
}

resource "cloudflare_zone_setting" "alacaba_browser_check" {
  zone_id    = data.cloudflare_zone.alacaba_org.id
  setting_id = "browser_check"
  value      = "on"
}
