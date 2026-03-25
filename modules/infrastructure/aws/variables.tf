variable "prefix" {
  description = "Prefix for all resources to ensure uniqueness"
  type        = string
  default     = "aws-tf"
}

variable "region" {
  description = "AWS region to deploy into"
  type        = string
  default     = "us-west-2"
}

variable "zone" {
  description = "Availability zone for the instance and EBS volume"
  type        = string
  default     = "us-west-2a"
}

variable "instance_type" {
  description = "Instance type for the VM (must support GPUs, e.g., g4dn.xlarge)"
  type        = string
  default     = "g4dn.xlarge"
}

variable "os_disk_size" {
  description = "Size of the root OS disk in GB"
  type        = number
  default     = 400
}

variable "create_ssh_key_pair" {
  description = "Whether to generate a new SSH key pair"
  type        = bool
  default     = true
}

variable "ssh_private_key_path" {
  description = "Path to save/read the private key (null for default naming)"
  type        = string
  default     = null
}

variable "ssh_public_key_path" {
  description = "Path to save/read the public key (null for default naming)"
  type        = string
  default     = null
}

variable "vpc_id" {
  description = "Existing VPC ID (leave null if creating a new VPC)"
  type        = string
  default     = null
}

variable "subnet_id" {
  description = "Existing Subnet ID (leave null if creating a new subnet)"
  type        = string
  default     = null
}

variable "ip_cidr_range" {
  description = "The IP range for the subnet"
  type        = string
  default     = "10.0.1.0/24"
}

variable "rke2_version" {
  description = "The version of RKE2 to install"
  type        = string
  default     = "v1.30.2+rke2r1"
}

variable "longhorn_chart_version" {
  description = "Specifies the longhorn chart version"
  type        = string
  default     = "v1.9.2"
}

variable "instance_count" {
  description = "The number of AWS instances to install"
  type        = number
  default     = 3
}

