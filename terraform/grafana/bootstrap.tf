resource "grafana_service_account" "terraform" {
  name        = "terraform"
  role        = "Admin"
  is_disabled = false
}

resource "grafana_service_account_token" "terraform" {
  name               = "terraform-token"
  service_account_id = grafana_service_account.terraform.id
}
