variable "grafana_url" {
  type        = string
  description = "Grafana HTTP API URL (e.g. http://grafana.local:30080)"
}

variable "grafana_auth" {
  type        = string
  sensitive   = true
  description = "Grafana auth: admin:<password> for bootstrap, or service-account token for normal use"
}
