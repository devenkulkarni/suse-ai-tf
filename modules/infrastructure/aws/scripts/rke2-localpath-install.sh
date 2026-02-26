#!/bin/bash
set -e

# Define absolute paths and LH version to install
K8S_BIN="/var/lib/rancher/rke2/bin/kubectl"
K8S_CONFIG="/etc/rancher/rke2/rke2.yaml"

echo "Starting RKE2 and Longhorn installation on SLES"

# 1. Create RKE2 directories
sudo mkdir -p /etc/rancher/rke2/
sudo mkdir -p /var/lib/rancher/rke2/server/manifests/

# 2. Generate Config
sudo tee /etc/rancher/rke2/config.yaml > /dev/null <<EOF
tls-san:
  - ${public_ip}
disable:
  - rke2-ingress-nginx
ingress-controller: traefik
EOF

# 3. Install RKE2
curl -sfL https://get.rke2.io | sudo INSTALL_RKE2_VERSION=${rke2_version} sh -

# 4. Enable and Start Service
sudo systemctl enable --now rke2-server

# 5. Wait for Service to be Active
TIMEOUT=600 # 10 minutes
END_TIME=$(( $${SECONDS} + $${TIMEOUT} ))

echo "Waiting for rke2-server to start (Timeout: $${TIMEOUT}s)..."

while true; do
    # 1. Check if the service is active (Success)
    if sudo systemctl is-active --quiet rke2-server; then
        echo "Success: rke2-server is active."
        break
    fi

    # 2. Check if the service explicitly failed (Early Exit)
    if sudo systemctl is-failed --quiet rke2-server; then
        echo "Error: rke2-server service entered a FAILED state."
        echo "--- Last 20 lines of logs ---"
        sudo journalctl -u rke2-server --no-pager -n 20
        exit 1
    fi

    # 3. Check for Timeout
    if [ "$${SECONDS}" -ge "$${END_TIME}" ]; then
        echo "Error: Timed out waiting for rke2-server after $${TIMEOUT} seconds."
        echo "--- Last 20 lines of logs ---"
        sudo journalctl -u rke2-server --no-pager -n 20
        exit 1
    fi

    sleep 5
done

# 6. Wait for Nodes to be Ready
echo "Waiting for kubectl to become responsive..."
until sudo $K8S_BIN --kubeconfig $K8S_CONFIG get nodes; do
    sleep 10
done

# 7. Install Longhornctl and Longhorn:
echo "Installing longhornctl..."
# Download to the current directory
sudo curl -sSfL -o /usr/local/bin/longhornctl https://github.com/longhorn/cli/releases/download/${longhorn_chart_version}/longhornctl-linux-amd64
sudo chmod +x /usr/local/bin/longhornctl

echo "Installing preflight...."
# Use the absolute path and pass the KUBECONFIG variable
sudo KUBECONFIG=$K8S_CONFIG /usr/local/bin/longhornctl install preflight

echo "Verify precheck...."
sudo KUBECONFIG=$K8S_CONFIG /usr/local/bin/longhornctl check preflight

echo "RKE2 installation completed successfully."
