#!/bin/bash

# Disable swap
swapoff -a
sed -i '/swap/d' /etc/fstab

# Load kernel modules
modprobe overlay
modprobe br_netfilter
echo "br_netfilter" | tee -a /etc/modules-load.d/containerd.conf
echo "overlay" | tee -a /etc/modules-load.d/containerd.conf

# Configure sysctl
cat <<EOF | tee /etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-iptables = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward = 1
EOF
sysctl --system

# Install containerd
apt-get update
apt-get install -y containerd
mkdir -p /etc/containerd
containerd config default | tee /etc/containerd/config.toml
sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
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

# No CNI installation needed - kubenet is built into Kubernetes
echo "=== Using kubenet for pod networking ==="

# Install Azure CLI
echo "=== Installing Azure CLI ==="
curl -sL https://aka.ms/InstallAzureCLIDeb | bash

# Login to Azure using managed identity
echo "=== Logging in to Azure ==="
az login --identity

# Get Azure subscription and tenant information
echo "=== Getting Azure subscription information ==="
AZURE_TENANT_ID=$(az account show --query tenantId -o tsv)
AZURE_SUBSCRIPTION_ID=$(az account show --query id -o tsv)

# Create Azure cloud config for worker node
echo "=== Creating Azure cloud config ==="
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

# Retrieve join command from Azure Key Vault
echo "=== Fetching kubeadm join command from Key Vault ==="
JOIN_COMMAND=""
MAX_RETRIES=5
RETRY_COUNT=0
while [ $RETRY_COUNT -lt $MAX_RETRIES ]; do
  JOIN_COMMAND=$(az keyvault secret show --vault-name ${KEY_VAULT_NAME} --name "kubeadm-join-command" --query value -o tsv 2>/dev/null)
  if [ -n "$JOIN_COMMAND" ]; then
    echo "Join command retrieved successfully"
    break
  fi
  echo "Failed to retrieve join command (attempt $((RETRY_COUNT+1))/$MAX_RETRIES). Retrying in 10 seconds..."
  sleep 10
  RETRY_COUNT=$((RETRY_COUNT+1))
done

if [ -n "$JOIN_COMMAND" ]; then
  echo "Executing join command..."
  $JOIN_COMMAND
else
  echo "ERROR: Could not retrieve join command from Key Vault"
fi

echo "=== Worker node setup completed ==="
