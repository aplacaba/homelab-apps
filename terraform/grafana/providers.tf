terraform {
  required_version = ">= 1.9"
  required_providers {
    grafana = {
      source  = "grafana/grafana"
      version = "~> 3.0"
    }
  }
  backend "s3" {
    bucket                      = "homelab-tfstate"
    key                         = "grafana/terraform.tfstate"
    region                      = "auto"
    use_path_style              = true
    skip_credentials_validation = true
    skip_region_validation      = true
    skip_requesting_account_id  = true
    skip_s3_checksum            = true
  }
}

provider "grafana" {
  url  = var.grafana_url
  auth = var.grafana_auth
}
