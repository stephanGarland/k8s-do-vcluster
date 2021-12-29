terraform {
    required_version = "~> 1.0.11"

    required_providers {
        digitalocean = {
        source = "digitalocean/digitalocean"
        version = "~> 2.0"
        }

        sops = {
            source = "carlpett/sops"
            version = "~> 0.6.3"
        }
    }
}

data "sops_file" "do_token" {
    source_file = "api.enc.json"
}

provider "digitalocean" {
    token = data.sops_file.do_token.data["api_token"]
}

locals {
    cluster_name = "sgarland-${var.env}-cluster"
    pool_name = "${local.cluster_name}-pool"
    k8s_version = replace(var.k8s_version, ".", "_")
    cluster_tags = [
        "${local.cluster_name}",
        "v${local.k8s_version}",
        var.region,
    ]
    worker_tags = [
        "${local.cluster_name}-worker",
        "v${local.k8s_version}",
        var.region,
        "k8s:worker",
    ]
}

resource "digitalocean_kubernetes_cluster" "k8s_cluster" {
    name    = local.cluster_name
    region  = var.region
    version = var.k8s_version
    tags    = local.cluster_tags

    node_pool {
        name       = local.pool_name
        size       = var.cluster_size
        auto_scale = var.auto_scale
        node_count = var.node_count
        tags       = local.worker_tags
    }
}
/*
resource "digitalocean_loadbalancer" "vcluster" {
    name = "${local.cluster_name}-lb"
    region = var.region
    droplet_tag = "k8s:worker"

    forwarding_rule {
        entry_port      = 443
        entry_protocol  = "tcp"
        target_port     = 32493
        target_protocol = "tcp"
        tls_passthrough = false
    }

    healthcheck {
        check_interval_seconds   = 3
        healthy_threshold        = 5
        port                     = 32493
        protocol                 = "tcp"
        response_timeout_seconds = 5
        unhealthy_threshold      = 3
    }
}
*/
output "cluster-id" {
    value = digitalocean_kubernetes_cluster.k8s_cluster.id
}
