output "tunnel_token" {
  value     = cloudflare_tunnel.main.tunnel_token
  sensitive = true
  description = "Token for cloudflared deployment"
}

output "watchtoken_api_token" {
  value     = cloudflare_api_token.cert_manager_watchtoken.value
  sensitive = true
  description = "API token for cert-manager DNS-01 on watchtoken.org"
}

output "alacaba_api_token" {
  value     = cloudflare_api_token.cert_manager_alacaba.value
  sensitive = true
  description = "API token for cert-manager DNS-01 on alacaba.org"
}
