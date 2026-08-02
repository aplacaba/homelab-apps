resource "cloudflare_zero_trust_tunnel_cloudflared" "main" {
  account_id = var.cloudflare_account_id
  name       = "k3s-tunnel"
}

resource "cloudflare_zero_trust_tunnel_cloudflared_config" "main" {
  tunnel_id  = cloudflare_zero_trust_tunnel_cloudflared.main.id
  account_id = var.cloudflare_account_id
  config = {
    ingress = [
      {
        hostname = "cv.alacaba.org"
        service  = local.tunnel_service
        origin_request = {
          no_tls_verify = true
        }
      },
      {
        hostname = "cv.watchtoken.org"
        service  = local.tunnel_service
        origin_request = {
          no_tls_verify = true
        }
      },
      {
        hostname = "fgit.watchtoken.org"
        service  = local.tunnel_service
        origin_request = {
          no_tls_verify = true
        }
      },
      {
        hostname = "vault.watchtoken.org"
        service  = local.tunnel_service
        origin_request = {
          no_tls_verify = true
        }
      },
      {
        hostname = "ssh.watchtoken.org"
        service  = "ssh://forgejo-ssh.forgejo.svc:22"
      },
      {
        hostname = "sync.watchtoken.org"
        service  = local.tunnel_service
        origin_request = {
          no_tls_verify = true
        }
      },
      {
        hostname = "history.watchtoken.org"
        service  = local.tunnel_service
        origin_request = {
          no_tls_verify = true
        }
      },
      {
        hostname = "spec.watchtoken.org"
        service  = local.tunnel_service
        origin_request = {
          no_tls_verify = true
        }
      },
      {
        service = "http_status:404"
      }
    ]
  }
}
