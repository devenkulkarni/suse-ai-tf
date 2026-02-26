locals {
  kc_path              = "${path.cwd}/kubeconfig-rke2.yaml"
  ssh_username         = var.ssh_username
  private_ssh_key_path = var.ssh_private_key_path == null ? "${path.cwd}/${var.prefix}-ssh_private_key.pem" : var.ssh_private_key_path
}

# Placeholder to satisfy provider init:
resource "local_file" "kubeconfig_placeholder" {
  count    = fileexists(local.kc_path) ? 0 : 1
  filename = local.kc_path
  content  = "apiVersion: v1\nkind: Config\nclusters: []\ncontexts: []\nusers: []"

  lifecycle {
    ignore_changes = [content]
  }
}


module "infrastructure" {
  source = "../../modules/infrastructure/aws"

  prefix               = var.prefix
  region               = var.region
  zone                 = var.zone
  instance_type        = var.instance_type
  os_disk_size         = var.os_disk_size
  create_ssh_key_pair  = var.create_ssh_key_pair
  ssh_private_key_path = var.ssh_private_key_path
  ssh_public_key_path  = var.ssh_public_key_path
  existing_key_name    = var.existing_key_name
  vpc_id               = var.vpc_id
  subnet_id            = var.subnet_id
  ip_cidr_range        = var.ip_cidr_range
  rke2_version         = var.rke2_version
}

resource "null_resource" "wait_for_k8s_api" {
  depends_on = [module.infrastructure, local_file.kubeconfig_placeholder]

  provisioner "local-exec" {
    # This loop checks for a successful connection to the API server
    command = <<EOT
      echo "Waiting for RKE2 API at ${local.kc_path}..."
      for i in {1..30}; do
        if kubectl --kubeconfig=${local.kc_path} cluster-info; then
          echo "Kubernetes API is reachable!"
          exit 0
        fi
        echo "Attempt $i: API not ready yet, sleeping 10s..."
        sleep 10
      done
      echo "Timed out waiting for Kubernetes API"
      exit 1
    EOT
  }
}

data "local_file" "kubeconfig_raw" {
  filename = local.kc_path

  depends_on = [null_resource.wait_for_k8s_api]
}

provider "kubernetes" {
  host                   = yamldecode(data.local_file.kubeconfig_raw.content).clusters[0].cluster.server
  client_certificate     = base64decode(yamldecode(data.local_file.kubeconfig_raw.content).users[0].user.client-certificate-data)
  client_key             = base64decode(yamldecode(data.local_file.kubeconfig_raw.content).users[0].user.client-key-data)
  cluster_ca_certificate = base64decode(yamldecode(data.local_file.kubeconfig_raw.content).clusters[0].cluster.certificate-authority-data)
}

provider "helm" {
  kubernetes = {
    host                   = yamldecode(data.local_file.kubeconfig_raw.content).clusters[0].cluster.server
    client_certificate     = base64decode(yamldecode(data.local_file.kubeconfig_raw.content).users[0].user.client-certificate-data)
    client_key             = base64decode(yamldecode(data.local_file.kubeconfig_raw.content).users[0].user.client-key-data)
    cluster_ca_certificate = base64decode(yamldecode(data.local_file.kubeconfig_raw.content).clusters[0].cluster.certificate-authority-data)
  }
}

module "kubernetes" {
  source     = "../../modules/kubernetes"
  depends_on = [null_resource.wait_for_k8s_api, data.local_file.kubeconfig_raw]

  providers = {
    kubernetes = kubernetes
    helm       = helm
  }

  instance_public_ip      = module.infrastructure.instance_public_ip
  ssh_private_key_content = module.infrastructure.ssh_private_key_content
  kubeconfig_path         = local.kc_path
  kubeconfig_ready_signal = module.infrastructure.kubeconfig_done

  registry_name          = var.registry_name
  registry_secretname    = var.registry_secretname
  registry_username      = var.registry_username
  registry_password      = var.registry_password
  suse_ai_namespace      = var.suse_ai_namespace
  cert_manager_namespace = var.cert_manager_namespace
  gpu_operator_ns        = var.gpu_operator_ns
  ssh_username           = local.ssh_username
}


# Integrate RKE2 cluster with existing Rancher Prime Manager
resource "rancher2_cluster" "rancher_cluster" {
  name  = var.prefix
  count = var.rancher_api_url != "" ? 1 : 0
}


# Wait for Rancher to generate the cluster registration token
resource "time_sleep" "wait_for_rancher_token" {
  count           = var.rancher_api_url != "" ? 1 : 0
  depends_on      = [rancher2_cluster.rancher_cluster]
  create_duration = "30s"
}

# Use a null_resource to execute the registration command on the target node
resource "null_resource" "apply_rancher_registration" {
  count = var.rancher_api_url != "" ? 1 : 0

  # Trigger the resource whenever the registration command changes
  triggers = {
    registration_command = rancher2_cluster.rancher_cluster[0].cluster_registration_token[0].insecure_command
  }

  # Connection block for the target RKE2 node
  connection {
    type        = "ssh"
    user        = local.ssh_username
    host        = module.infrastructure.instance_public_ip
    private_key = file(local.private_ssh_key_path)
  }

  provisioner "remote-exec" {
    inline = compact([
      "export KUBECONFIG=/tmp/rke2.yaml",
      "echo 'Applying Rancher registration command...'",
      # Execute the command provided by Rancher
      rancher2_cluster.rancher_cluster[0].cluster_registration_token[0].insecure_command
    ])
  }

  # Ensure the null_resource only runs after the cluster token is generated
  depends_on = [rancher2_cluster.rancher_cluster, time_sleep.wait_for_rancher_token]
}
