variable "kubeconfig_path" {
  description = "Path to the kubeconfig file"
  type        = string
}

variable "kubeconfig_ready_signal" {
  description = "Path to the file that signals the kubeconfig is ready"
  type        = string
}

variable "instance_public_ip" {
  description = "Public IP of the instance"
  type        = string
}

variable "ssh_username" {
  description = "SSH username for logging into the instance"
  type        = string
}

variable "ssh_private_key_content" {
  description = "Content of the SSH private key"
  type        = string
  sensitive   = true
}

variable "use_existing_ssh_public_key" {
  description = "Whether to use an existing SSH public key"
  type        = bool
  default     = false
}

variable "registry_name" {
  type        = string
  default     = "dp.apps.rancher.io"
  description = "Name of the application collection registry"
}

variable "registry_secretname" {
  type        = string
  default     = "application-collection"
  description = "Name of the secret for accessing the registry"
}

variable "registry_username" {
  type        = string
  description = "Username for the registry"
}

variable "registry_password" {
  type        = string
  description = "Password/Token for the registry"
  sensitive   = true
}

variable "suse_ai_namespace" {
  type        = string
  default     = "suse-ai"
  description = "Name of the namespace where you want to deploy SUSE AI Stack!"
}

variable "cert_manager_namespace" {
  type        = string
  default     = "cert-manager"
  description = "Name of the namespace where you want to deploy cert-manager"
}

variable "gpu_operator_ns" {
  type        = string
  description = "Namespace for the NVIDIA GPU operator"
  default     = "gpu-operator"
}

variable "letsencrypt_acme_server" {
  type        = string
  description = "Acme server"
  default     = "https://acme-staging-v02.api.letsencrypt.org/directory"
}

variable "deployer_chart_version" {
  type        = string
  description = "Chart version for the suse-ai-deployer helm chart"
  default     = "1.1.0"
}
