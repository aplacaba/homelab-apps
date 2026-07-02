output "grafana_token" {
  value       = grafana_service_account_token.terraform.key
  sensitive   = true
  description = "SA token for GRAFANA_AUTH on subsequent applies"
}
