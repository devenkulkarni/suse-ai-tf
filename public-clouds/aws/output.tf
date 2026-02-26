output "suse_ai_webui_url" {
  description = "URL for accessing the SUSE AI webUI"
  value       = "suse-ai.${module.infrastructure.instance_public_ip}.sslip.io"
}

output "instance_public_ip" {
  description = "The public IP of the openSUSE VM"
  value       = module.infrastructure.instance_public_ip
}

output "kubeconfig_path" {
  description = "The local path to the generated kubeconfig file"
  value       = "${path.cwd}/kubeconfig-rke2.yaml"
}

output "ssh_command" {
  description = "Command to connect to the VM"
  value       = "ssh -i ${local.private_ssh_key_path} ${var.ssh_username}@${module.infrastructure.instance_public_ip}"
}
