terraform {
  required_providers {
    kind = {
      source = "tehcyx/kind"
      version = "0.5.1"
    }

    kubectl = {
      source  = "alekc/kubectl"
      version = ">= 2.0.4"
    }

    kubernetes = {
      source = "hashicorp/kubernetes"
      version = "2.30.0"
    }
  }
}

provider "kind" {}

provider "kubectl" {
  host = "${kind_cluster.default.endpoint}"
  cluster_ca_certificate = "${kind_cluster.default.cluster_ca_certificate}"
  client_certificate = "${kind_cluster.default.client_certificate}"
  client_key = "${kind_cluster.default.client_key}"
}

provider "helm" {
  kubernetes {
    host = "${kind_cluster.default.endpoint}"
    cluster_ca_certificate = "${kind_cluster.default.cluster_ca_certificate}"
    client_certificate = "${kind_cluster.default.client_certificate}"
    client_key = "${kind_cluster.default.client_key}"
  }
  debug = true
}

provider "kubernetes" {
  host = "${kind_cluster.default.endpoint}"
  cluster_ca_certificate = "${kind_cluster.default.cluster_ca_certificate}"
  client_certificate = "${kind_cluster.default.client_certificate}"
  client_key = "${kind_cluster.default.client_key}"
}

## ---------------------------------------------
## Kind Cluster
## ---------------------------------------------
resource "kind_cluster" "default" {
  name = "lgtm"
  wait_for_ready = true
  kind_config {
    kind = "Cluster"
    api_version = "kind.x-k8s.io/v1alpha4"
    containerd_config_patches = [
      <<-TOML
        [plugins."io.containerd.grpc.v1.cri".registry.mirrors."localhost:5000"]
            endpoint = ["http://kind-registry:5000"]
        TOML
    ]

    node {
      role = "control-plane"
      image = "kindest/node:v1.29.4"
      kubeadm_config_patches = [
        "kind: InitConfiguration\nnodeRegistration:\n  kubeletExtraArgs:\n    node-labels: \"ingress-ready=true\"\n"
      ]

      extra_port_mappings {
        container_port = 80
        host_port      = 80
        protocol = "TCP"
      }
      extra_port_mappings {
        container_port = 443
        host_port      = 443
        protocol = "TCP"
      }
    }

    node {
      role = "worker"
      image = "kindest/node:v1.29.4"
    }

    node {
      role = "worker"
      image = "kindest/node:v1.29.4"
    }

    node {
      role = "worker"
      image = "kindest/node:v1.29.4"
    }
  }
}

## ---------------------------------------------
## Setup a local registry hosted in Kind to be
## used from your local machine
## ---------------------------------------------

resource "null_resource" "local_registry" {
  depends_on = [kind_cluster.default]
  provisioner "local-exec" {
    command = "/bin/sh scripts/create-local-registry.sh"
  }

  provisioner "local-exec" {
    command = "/bin/sh scripts/connect-registry.sh"
  }
}

data "kubectl_file_documents" "local_registry_cm_doc" {
  content = yamlencode({
    apiVersion = "v1"
    kind       = "ConfigMap"
    metadata = {
      name      = "local-registry-hosting"
      namespace = "kube-public"
    }
    data = {
      "localRegistryHosting.v1" = <<-EOF
        host: "localhost:5001"
        help: "https://kind.sigs.k8s.io/docs/user/local-registry/"
      EOF
    }
  })
}

resource "kubectl_manifest" "local_registry_cm" {
  depends_on = [data.kubectl_file_documents.local_registry_cm_doc, kind_cluster.default]
  for_each  = data.kubectl_file_documents.local_registry_cm_doc.manifests
  yaml_body = each.value
}

## ---------------------------------------------
## ArgoCD - helm install
## ---------------------------------------------
resource "helm_release" "argocd" {
  name  = "argocd"

  repository       = "https://argoproj.github.io/argo-helm"
  chart            = "argo-cd"
  namespace        = "argocd"
  version          = "7.0.0"
  create_namespace = true

  values = [
    yamlencode({
      configs = {
        params = {
          "server.insecure" = "true"
          "server.disable.auth" = true
        }
      }
    })
  ]

  depends_on = [
    kind_cluster.default
  ]
}

resource "helm_release" "argocd_apps" {
  name  = "argocd-apps"

  repository       = "https://argoproj.github.io/argo-helm"
  chart            = "argocd-apps"
  namespace        = "argocd"
  version          = "2.0.0"
  create_namespace = true

  values = [
    yamlencode({
      applications = {
        app-of-apps = {
          namespace = "argocd"
          project = "default"
          source = {
            repoURL = "https://github.com/fishst1k/lgtm-kind.git"
            targetRevision = "HEAD"
            path = "argocd"
            directory = {
              recurse = true
            }
          }
          destination = {
            server = "https://kubernetes.default.svc"
            namespace = "argocd"
          }
          syncPolicy = {
            automated = {
              prune    = true
              selfHeal = true
            }
          }
        }
      }
    })
  ]

  depends_on = [
    helm_release.argocd
  ]
}