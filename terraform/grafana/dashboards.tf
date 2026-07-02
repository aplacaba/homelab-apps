locals {
  dashboards = toset([
    "cluster-overview",
    "nodes",
    "pods-workloads",
    "traefik",
    "forgejo",
    "storage-pvc",
    "cloudflare-tunnel",
  ])
}

resource "grafana_dashboard" "this" {
  for_each    = local.dashboards
  folder      = grafana_folder.homelab.uid
  config_json = file("${path.module}/dashboards/${each.key}.json")
  overwrite   = true
}
