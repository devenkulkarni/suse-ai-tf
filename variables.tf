variable "instance_prefix" {
  type        = string
  default     = "suse-ai"
  description = "Prefix added to names of EC2 instance"
}

variable "aws_region" {
  type        = string
  description = "Specifies the AWS region to deploy all resources"
}

variable "instance_type" {
  type        = string
  default     = "g4dn.xlarge"
  description = "Type of EC2 instance"
}

variable "use_existing_ssh_public_key" {
  type        = bool
  default     = false
  description = "Boolean to check if using existing SSH key"
}

variable "user_ssh_private_key" {
  type        = string
  default     = null
  description = "SSH Private key path"
}

variable "user_ssh_public_key" {
  type        = string
  default     = null
  description = "SSH Public key path"
}

variable "registration_code" {
  type        = string
  description = "SUSE registration code"
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

variable "kubeconfig_path" {
  type        = string
  description = "kubeconfig file for accessing cluster"
  default     = null
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
  default     = "gpu-operator-resources"
  description = "Namespace for the NVIDIA GPU operator"
}
