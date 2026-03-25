#!/bin/bash
set -e

# Define absolute paths to avoid PATH issues in remote-exec
K8S_BIN="/var/lib/rancher/rke2/bin/kubectl"
K8S_CONFIG="/etc/rancher/rke2/rke2.yaml"

if [ ! -f /tmp/rke2-token ]; then
  echo "ERROR: token file missing"
  exit 1
fi

# Updating the environment variable. 
TOKEN=$(sudo cat /tmp/rke2-token)

echo "Starting RKE2 installation for additional servers..."

# 1. Create RKE2 directories
sudo mkdir -p /etc/rancher/rke2/
sudo mkdir -p /var/lib/rancher/rke2/server/manifests/

# 2. Generate Config
sudo tee /etc/rancher/rke2/config.yaml > /dev/null <<EOF
server: https://${private_ip}:9345
token: $${TOKEN}
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

# 6. Apply Local Path Provisioner
echo "Applying Local Path Provisioner..."
# We use the absolute path to kubectl and point to the config explicitly
sudo $K8S_BIN --kubeconfig $K8S_CONFIG apply -f https://raw.githubusercontent.com/rancher/local-path-provisioner/v0.0.31/deploy/local-path-storage.yaml

echo "RKE2 installation with localpath storage provisioner completed successfully for additional server."

# 6. Wait for Nodes to be Ready
echo "Waiting for kubectl to become responsive..."
until sudo $K8S_BIN --kubeconfig $K8S_CONFIG get nodes; do
    sleep 10
done

# 7. Install Longhorn pre-requisites:
echo "Installing longhorn pre-requisites [nfs-client, iscsi, cryptsetup]"

sudo zypper install -y nfs-client open-iscsi cryptsetup

echo "Enabling and starting iscsid..."
sudo systemctl enable --now iscsid

# 8. Wait for Service to be Active
TIMEOUT=600 # 10 minutes
END_TIME=$(( $${SECONDS} + $${TIMEOUT} ))

echo "Waiting for iscsid to start (Timeout: $${TIMEOUT}s)..."

while true; do
    # 1. Check if the service is active (Success)
    if sudo systemctl is-active --quiet iscsid; then
        echo "Success: iscsid is active."
        break
    fi

    # 2. Check if the service explicitly failed (Early Exit)
    if sudo systemctl is-failed --quiet iscsid; then
        echo "Error: iscsid service entered a FAILED state."
        echo "--- Last 20 lines of logs ---"
        sudo journalctl -u rke2-server --no-pager -n 20
        exit 1
    fi

    # 3. Check for Timeout
    if [ "$${SECONDS}" -ge "$${END_TIME}" ]; then
        echo "Error: Timed out waiting for iscsid after $${TIMEOUT} seconds."
        echo "--- Last 20 lines of logs ---"
        sudo journalctl -u iscsid --no-pager -n 20
        exit 1
    fi

    sleep 5
done


echo "RKE2 installation with Longhorn storage provisioner completed successfully for additional servers."
