data "cloudflare_zone" "watchtoken_org" {
  filter = {
    name = "watchtoken.org"
  }
}

data "cloudflare_zone" "alacaba_org" {
  filter = {
    name = "alacaba.org"
  }
}

resource "cloudflare_dns_record" "cv_watchtoken" {
  zone_id = data.cloudflare_zone.watchtoken_org.id
  name    = "cv"
  content = "${cloudflare_zero_trust_tunnel_cloudflared.main.id}.cfargotunnel.com"
  type    = "CNAME"
  ttl     = 1
  proxied = true
}

resource "cloudflare_dns_record" "fgit_watchtoken" {
  zone_id = data.cloudflare_zone.watchtoken_org.id
  name    = "fgit"
  content = "${cloudflare_zero_trust_tunnel_cloudflared.main.id}.cfargotunnel.com"
  type    = "CNAME"
  ttl     = 1
  proxied = true
}

resource "cloudflare_dns_record" "vault_watchtoken" {
  zone_id = data.cloudflare_zone.watchtoken_org.id
  name    = "vault"
  content = "${cloudflare_zero_trust_tunnel_cloudflared.main.id}.cfargotunnel.com"
  type    = "CNAME"
  ttl     = 1
  proxied = true
}

resource "cloudflare_dns_record" "ssh_watchtoken" {
  zone_id = data.cloudflare_zone.watchtoken_org.id
  name    = "ssh"
  content = "${cloudflare_zero_trust_tunnel_cloudflared.main.id}.cfargotunnel.com"
  type    = "CNAME"
  ttl     = 1
  proxied = true
}

resource "cloudflare_dns_record" "cv_alacaba" {
  zone_id = data.cloudflare_zone.alacaba_org.id
  name    = "cv"
  content = "${cloudflare_zero_trust_tunnel_cloudflared.main.id}.cfargotunnel.com"
  type    = "CNAME"
  ttl     = 1
  proxied = true
}
