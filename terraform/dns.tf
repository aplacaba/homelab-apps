data "cloudflare_zone" "watchtoken_org" {
  name = "watchtoken.org"
}

data "cloudflare_zone" "alacaba_org" {
  name = "alacaba.org"
}

resource "cloudflare_dns_record" "cv_watchtoken" {
  zone_id = data.cloudflare_zone.watchtoken_org.id
  name    = "cv"
  content = cloudflare_tunnel.main.cname
  type    = "CNAME"
  proxied = true
}

resource "cloudflare_dns_record" "fgit_watchtoken" {
  zone_id = data.cloudflare_zone.watchtoken_org.id
  name    = "fgit"
  content = cloudflare_tunnel.main.cname
  type    = "CNAME"
  proxied = true
}

resource "cloudflare_dns_record" "vault_watchtoken" {
  zone_id = data.cloudflare_zone.watchtoken_org.id
  name    = "vault"
  content = cloudflare_tunnel.main.cname
  type    = "CNAME"
  proxied = true
}

resource "cloudflare_dns_record" "cv_alacaba" {
  zone_id = data.cloudflare_zone.alacaba_org.id
  name    = "cv"
  content = cloudflare_tunnel.main.cname
  type    = "CNAME"
  proxied = true
}
