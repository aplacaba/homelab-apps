resource "random_password" "tunnel_secret" {
  length  = 64
  special = false
}

resource "cloudflare_tunnel" "main" {
  account_id = var.cloudflare_account_id
  name       = "k3s-tunnel"
  secret     = random_password.tunnel_secret.result
}

resource "cloudflare_tunnel_config" "main" {
  tunnel_id  = cloudflare_tunnel.main.id
  account_id = var.cloudflare_account_id

  config {
    ingress_rule {
      hostname = "cv.alacaba.org"
      service  = local.tunnel_service
      origin_request {
        no_tls_verify = true
      }
    }
    ingress_rule {
      hostname = "cv.watchtoken.org"
      service  = local.tunnel_service
      origin_request {
        no_tls_verify = true
      }
    }
    ingress_rule {
      hostname = "fgit.watchtoken.org"
      service  = local.tunnel_service
      origin_request {
        no_tls_verify = true
      }
    }
    ingress_rule {
      hostname = "vault.watchtoken.org"
      service  = local.tunnel_service
      origin_request {
        no_tls_verify = true
      }
    }
    ingress_rule {
      service = "http_status:404"
    }
  }
}
