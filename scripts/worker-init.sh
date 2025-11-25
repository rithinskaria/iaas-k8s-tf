#!/bin/bash

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

# Install containerd from Docker's official repository
echo "=== Installing containerd ==="
apt-get update
apt-get install -y ca-certificates curl gnupg lsb-release
mkdir -p /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null
apt-get update
apt-get install -y containerd.io

# Configure containerd
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
echo "=== Installing Azure CLI ==="
curl -sL https://aka.ms/InstallAzureCLIDeb | bash

# Login to Azure using managed identity
echo "=== Logging in to Azure ==="
az login --identity

# Get Azure subscription and tenant information
echo "=== Getting Azure subscription information ==="
AZURE_TENANT_ID=$(az account show --query tenantId -o tsv)
AZURE_SUBSCRIPTION_ID=$(az account show --query id -o tsv)

# Create Azure cloud config for worker node BEFORE joining cluster
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

echo "=== Azure cloud config created successfully ==="
ls -la /etc/kubernetes/azure.json

# Configure kubelet to use external cloud provider
echo "=== Configuring kubelet for external cloud provider ==="
mkdir -p /etc/default
cat > /etc/default/kubelet <<EOFKUBELET
KUBELET_EXTRA_ARGS="--cloud-provider=external"
EOFKUBELET

# Retrieve join command from Azure Key Vault
echo "=== Fetching kubeadm join command from Key Vault ==="
JOIN_COMMAND=""
MAX_RETRIES=20
RETRY_COUNT=0
while [ $RETRY_COUNT -lt $MAX_RETRIES ]; do
  JOIN_COMMAND=$(az keyvault secret show --vault-name ${KEY_VAULT_NAME} --name "kubeadm-join-command" --query value -o tsv 2>/dev/null)
  if [ -n "$JOIN_COMMAND" ]; then
    echo "Join command retrieved successfully"
    break
  fi
  echo "Failed to retrieve join command (attempt $((RETRY_COUNT+1))/$MAX_RETRIES). Retrying in 15 seconds..."
  sleep 15
  RETRY_COUNT=$((RETRY_COUNT+1))
done

if [ -n "$JOIN_COMMAND" ]; then
  
  echo "Executing join command..."
  $JOIN_COMMAND
  sleep 30  
  if [ $? -eq 0 ]; then
    echo "Successfully joined the cluster"
    
    # Verify kubelet is running with cloud provider
    echo "=== Verifying kubelet configuration ==="
    sleep 10
    systemctl status kubelet --no-pager || true
    
    # Check if kubelet is using external cloud provider
    if ps aux | grep kubelet | grep -q "cloud-provider=external"; then
      echo "✓ Kubelet is configured with external cloud provider"
    else
      echo "⚠ Warning: Kubelet may not be using external cloud provider"
    fi
    
    # Verify azure.json is accessible
    if [ -f /etc/kubernetes/azure.json ]; then
      echo "✓ Azure cloud config is present"
    else
      echo "✗ ERROR: Azure cloud config is missing"
    fi
    
    # Wait for initial setup to complete, then restart kubelet to ensure all configs are applied
    echo "=== Waiting for node initialization ==="
    sleep 60
    
    echo "=== Restarting kubelet to apply all configurations ==="
    systemctl restart kubelet
    
    echo "✓ Kubelet restarted successfully"
    
    # Apply node labels and taints
    echo "=== Applying node pool configuration ==="
    
    # Install jq if not present
    if ! command -v jq &> /dev/null; then
      echo "Installing jq..."
      apt-get install -y jq
    fi
    
    # Get node name (VMSS instances have specific naming)
    HOSTNAME=$(hostname)
    echo "Node hostname: $HOSTNAME"
    
    # Wait for node to be fully registered
    echo "Waiting for node to be fully registered..."
    sleep 30
    
    # Apply labels if provided
    NODE_LABELS='${NODE_LABELS}'
    if [ "$NODE_LABELS" != "null" ] && [ "$NODE_LABELS" != "{}" ] && [ -n "$NODE_LABELS" ]; then
      echo "Applying labels: $NODE_LABELS"
      
      # Parse and apply each label
      for label in $(echo "$NODE_LABELS" | jq -r 'to_entries[] | "\(.key)=\(.value)"'); do
        echo "Applying label: $label"
        max_attempts=5
        attempt=1
        while [ $attempt -le $max_attempts ]; do
          if kubectl --kubeconfig=/etc/kubernetes/kubelet.conf label node "$HOSTNAME" "$label" --overwrite; then
            echo "✓ Label applied: $label"
            break
          else
            echo "⚠ Attempt $attempt/$max_attempts failed for label: $label"
            sleep 10
            attempt=$((attempt + 1))
          fi
        done
      done
    fi
    
    # Note: Taints are now managed by the CronJob taint-manager in kube-system namespace
    # This ensures consistent taint application and supports autoscaling scenarios
    
    echo "✓ Node pool configuration applied"
  else
    echo "ERROR: Failed to join cluster"
    exit 1
  fi
else
  echo "ERROR: Could not retrieve join command from Key Vault after $MAX_RETRIES attempts"
  exit 1
fi

echo "=== Worker node setup completed ==="
