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

resource "cloudflare_dns_record" "ssh_watchtoken" {
  zone_id = data.cloudflare_zone.watchtoken_org.id
  name    = "ssh"
  content = "${cloudflare_zero_trust_tunnel_cloudflared.main.id}.cfargotunnel.com"
  type    = "CNAME"
  ttl     = 1
  proxied = true
}

resource "cloudflare_dns_record" "sync_watchtoken" {
  zone_id = data.cloudflare_zone.watchtoken_org.id
  name    = "sync"
  content = "${cloudflare_zero_trust_tunnel_cloudflared.main.id}.cfargotunnel.com"
  type    = "CNAME"
  ttl     = 1
  proxied = true
}

resource "cloudflare_dns_record" "history_watchtoken" {
  zone_id = data.cloudflare_zone.watchtoken_org.id
  name    = "history"
  content = "${cloudflare_zero_trust_tunnel_cloudflared.main.id}.cfargotunnel.com"
  type    = "CNAME"
  ttl     = 1
  proxied = true
}

resource "cloudflare_dns_record" "spec_watchtoken" {
  zone_id = data.cloudflare_zone.watchtoken_org.id
  name    = "spec"
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

resource "cloudflare_dns_record" "watchtoken_apex" {
  zone_id = data.cloudflare_zone.watchtoken_org.id
  name    = "watchtoken.org"
  content = var.pangolin_vps_ip
  type    = "A"
  ttl     = 1
  proxied = false
}

resource "cloudflare_dns_record" "seerr_watchtoken" {
  zone_id = data.cloudflare_zone.watchtoken_org.id
  name    = "seerr"
  content = var.pangolin_vps_ip
  type    = "A"
  ttl     = 1
  proxied = false
}

resource "cloudflare_dns_record" "pangolin_watchtoken" {
  zone_id = data.cloudflare_zone.watchtoken_org.id
  name    = "pangolin"
  content = var.pangolin_vps_ip
  type    = "A"
  ttl     = 1
  proxied = false
}
