# Ensure kubeconfig is ready before proceeding
resource "null_resource" "validate_kubernetes_connection" {
  # The reference to the signal file creates an implicit dependency
  triggers = {
    signal_file = var.kubeconfig_ready_signal
  }

  provisioner "local-exec" {
    command = <<-EOT
echo "Waiting for Kubernetes API..."

for i in {1..30}; do
  if kubectl --kubeconfig=${var.kubeconfig_path} get nodes >/dev/null 2>&1; then
    echo "Kubernetes API reachable"
    exit 0
  fi

  echo "API not ready yet... retrying"
  sleep 10
done

echo "Failed to connect to Kubernetes cluster"
exit 1
EOT
  }
}
