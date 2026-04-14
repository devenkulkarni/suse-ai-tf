output "instance_public_ip" {
 #value = aws_instance.opensuse_gpu[0].public_ip
  value = aws_eip.ec2_eip[0].public_ip
}

output "kubeconfig_path" {
  value = "${path.cwd}/kubeconfig-rke2.yaml"
}

output "ssh_command" {
  description = "Convenience command to login"
 #value       = "ssh -i ${local.private_ssh_key_path} ${local.ssh_username}@${aws_instance.opensuse_gpu[0].public_ip}"
  value       = "ssh -i ${local.private_ssh_key_path} ${local.ssh_username}@${aws_eip.ec2_eip[0].public_ip}"
}

output "kubeconfig_done" {
  value = null_resource.retrieve_kubeconfig.id
}

output "ssh_private_key_content" {
  description = "The content of the generated private key"
  value       = var.create_ssh_key_pair ? tls_private_key.ssh_private_key[0].private_key_openssh : file(local.private_ssh_key_path)
  sensitive   = true
}
