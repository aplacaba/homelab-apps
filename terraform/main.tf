variable "cloudflare_api_token" {
  type        = string
  sensitive   = true
  description = "Cloudflare API token with Zone:Read, DNS:Edit, Tunnel:Edit, API Tokens:Write"
}

variable "cloudflare_account_id" {
  type        = string
  description = "Cloudflare account ID (visible in dashboard URL)"
}

locals {
  tunnel_service = "https://traefik.traefik.svc:443"
}
