#!/bin/bash

set -euo pipefail

log() { echo "[$(date -Is)] $*"; }

retry() {
  local max_attempts=$1; shift
  local sleep_seconds=$1; shift
  local attempt=1
  until "$@"; do
    if [ "$attempt" -ge "$max_attempts" ]; then
      log "ERROR: Command failed after ${attempt} attempts: $*"
      return 1
    fi
    log "WARN: Command failed (attempt ${attempt}/${max_attempts}), retrying in ${sleep_seconds}s..."
    sleep "${sleep_seconds}"
    attempt=$((attempt+1))
  done
}

# Disable swap
swapoff -a
sed -i '/swap/d' /etc/fstab

# Load kernel modules
modprobe overlay
modprobe br_netfilter
echo "br_netfilter" | tee -a /etc/modules-load.d/containerd.conf
echo "overlay" | tee -a /etc/modules-load.d/containerd.conf

# Configure sysctl (only parameters that work in Azure VMs)
cat <<EOF | tee /etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-iptables = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward = 1
EOF
sysctl -p /etc/sysctl.d/k8s.conf

# Install containerd
apt-get update
apt-get install -y containerd
mkdir -p /etc/containerd
containerd config default | tee /etc/containerd/config.toml
sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
# Update pause image to match kubeadm's expected version
sed -i 's|sandbox_image = "registry.k8s.io/pause:.*"|sandbox_image = "registry.k8s.io/pause:3.10.1"|' /etc/containerd/config.toml
systemctl restart containerd
systemctl enable containerd

# Install Kubernetes components
mkdir -p /etc/apt/keyrings
curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.34/deb/Release.key | gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
echo 'deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.34/deb/ /' | tee /etc/apt/sources.list.d/kubernetes.list
apt-get update
apt-get install -y kubelet kubeadm kubectl
apt-mark hold kubelet kubeadm kubectl

# Ensure IP forwarding is enabled at the interface level
echo "=== Enabling IP forwarding on network interface ==="
PRIMARY_IFACE=$(ip route | grep default | awk '{print $5}' | head -n1)
echo "Primary interface: $PRIMARY_IFACE"

# Enable IP forwarding on the interface
echo 1 > /proc/sys/net/ipv4/ip_forward
sysctl -w net.ipv4.ip_forward=1
sysctl -w net.ipv4.conf.all.forwarding=1
sysctl -w net.ipv4.conf.$PRIMARY_IFACE.forwarding=1

# Verify IP forwarding is enabled
IP_FORWARD=$(cat /proc/sys/net/ipv4/ip_forward)
if [ "$IP_FORWARD" != "1" ]; then
  echo "ERROR: IP forwarding is not enabled!"
  exit 1
fi
echo "IP forwarding verified: enabled"

# Install Azure CLI first to retrieve join command and create cloud config
log "=== Installing Azure CLI ==="
curl -sL https://aka.ms/InstallAzureCLIDeb | bash

# Login to Azure using managed identity with retries
log "=== Logging in to Azure with managed identity ==="
retry 10 15 az login --identity --allow-no-subscriptions

# Get Azure subscription and tenant information with retries
log "=== Getting Azure subscription information ==="
AZURE_TENANT_ID=$(retry 10 10 az account show --query tenantId -o tsv)
AZURE_SUBSCRIPTION_ID=$(retry 10 10 az account show --query id -o tsv)

# Create Azure cloud config for worker node BEFORE joining cluster
log "=== Creating Azure cloud config ==="
mkdir -p /etc/kubernetes
cat > /etc/kubernetes/azure.json <<EOFAZURE
{
  "cloud": "AzurePublicCloud",
  "tenantId": "$AZURE_TENANT_ID",
  "subscriptionId": "$AZURE_SUBSCRIPTION_ID",
  "resourceGroup": "${RESOURCE_GROUP_NAME}",
  "location": "${LOCATION}",
  "vmType": "${VM_TYPE}",
  "vnetName": "${VNET_NAME}",
  "vnetResourceGroup": "${RESOURCE_GROUP_NAME}",
  "subnetName": "${SUBNET_NAME}",
  "securityGroupName": "${NSG_NAME}",
  "useManagedIdentityExtension": true,
  "userAssignedIdentityID": "${MI_CLIENT_ID}",
  "useInstanceMetadata": true,
  "loadBalancerSku": "Standard",
  "maximumLoadBalancerRuleCount": 250,
  "excludeMasterFromStandardLB": true
}
EOFAZURE
chmod 644 /etc/kubernetes/azure.json

log "=== Azure cloud config created successfully ==="
ls -la /etc/kubernetes/azure.json

# Configure kubelet to use external cloud provider
log "=== Configuring kubelet for external cloud provider ==="
mkdir -p /etc/default
cat > /etc/default/kubelet <<EOFKUBELET
KUBELET_EXTRA_ARGS="--cloud-provider=external"
EOFKUBELET

# Retrieve join command from Azure Key Vault with extended retries
log "=== Fetching kubeadm join command from Key Vault ==="
JOIN_COMMAND=""
MAX_RETRIES=40
RETRY_DELAY=15

for ((i=1; i<=MAX_RETRIES; i++)); do
  set +e
  JOIN_COMMAND=$(az keyvault secret show \
    --vault-name "${KEY_VAULT_NAME}" \
    --name "kubeadm-join-command" \
    --query value -o tsv 2>/dev/null)
  status=$?
  set -e
  if [ "$status" -eq 0 ] && [ -n "$JOIN_COMMAND" ]; then
    log "Join command retrieved successfully (attempt ${i}/${MAX_RETRIES})"
    break
  fi
  log "Join command not available yet (attempt ${i}/${MAX_RETRIES}); sleeping ${RETRY_DELAY}s..."
  sleep "${RETRY_DELAY}"
done

if [ -z "$JOIN_COMMAND" ]; then
  log "ERROR: Could not retrieve join command from Key Vault after ${MAX_RETRIES} attempts"
  exit 1
fi

# Check if node is already joined to avoid re-joining
log "=== Checking if node is already joined ==="
if [ -f /etc/kubernetes/kubelet.conf ]; then
  log "Node already appears joined (kubelet.conf present); skipping join."
else
  log "Waiting 30s before executing join command to allow master to be ready..."
  sleep 30
  
  log "Executing join command..."
  eval "$JOIN_COMMAND"
  
  if [ $? -eq 0 ]; then
    log "Successfully joined the cluster"
  else
    log "ERROR: Failed to join cluster"
    exit 1
  fi
fi

# Verify kubelet is running and healthy
log "=== Verifying kubelet is running and healthy ==="
for i in {1..20}; do
  set +e
  systemctl is-active --quiet kubelet
  status=$?
  set -e
  if [ "$status" -eq 0 ]; then
    log "kubelet is active"
    break
  fi
  log "kubelet not active yet (attempt ${i}/20); sleeping 10s..."
  sleep 10
done

log "=== Kubelet status ==="
systemctl status kubelet --no-pager || true

# Check if kubelet is using external cloud provider
log "=== Verifying kubelet cloud provider configuration ==="
if ps aux | grep kubelet | grep -q "cloud-provider=external"; then
  log "✓ Kubelet is configured with external cloud provider"
else
  log "⚠ Warning: Kubelet may not be using external cloud provider"
fi

# Verify azure.json is accessible
if [ -f /etc/kubernetes/azure.json ]; then
  log "✓ Azure cloud config is present"
else
  log "✗ ERROR: Azure cloud config is missing"
fi

log "=== Worker node setup completed ==="
