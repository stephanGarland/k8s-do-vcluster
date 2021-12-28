variable auto_scale {
    description = "Whether to enable auto-scaling."
    type        = bool
    default     = false
}

variable cluster_size {
    description = "The size of the cluster to create."
    type        = string
    default     = "s-2vcpu-4gb"
}

variable env {
    description = "The environment to use."
    type        = string
}

variable k8s_version {
    description = "The version of Kubernetes to use."
    type        = string
    default     = "1.20.11-do.0"
}

variable node_count {
    description = "The number of nodes to create."
    type        = number
    default     = 3
}

variable region {
    description = "The region to use."
    type        = string
    default     = "nyc1"
}
