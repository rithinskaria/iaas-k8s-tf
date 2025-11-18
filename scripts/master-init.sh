#!/bin/bash
set -e

CONTROL_PLANE_IP=$(hostname -I | awk '{print $1}')

echo "=== Step 1: Disable swap ==="
swapoff -a
sed -i '/swap/d' /etc/fstab

echo "=== Step 2: Load required kernel modules ==="
modprobe overlay
modprobe br_netfilter
cat <<EOF | tee /etc/modules-load.d/k8s.conf
overlay
br_netfilter
EOF

echo "=== Step 3: Configure sysctl for Kubernetes ==="
cat <<EOF | tee /etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF
sysctl --system

echo "=== Step 4: Install containerd ==="
apt-get update
apt-get install -y containerd
mkdir -p /etc/containerd
containerd config default > /etc/containerd/config.toml
sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
systemctl restart containerd
systemctl enable containerd

echo "=== Step 5: Install kubeadm, kubelet, kubectl ==="
mkdir -p /etc/apt/keyrings
curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.34/deb/Release.key | gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
apt-get update
apt-get install -y kubelet kubeadm kubectl
apt-mark hold kubelet kubeadm kubectl

echo "=== Step 6: Download and install Azure CNI plugin ==="
# Download Azure CNI plugin
AZURE_CNI_VERSION="v1.6.6"
CNI_PLUGIN_VERSION="v1.6.1"

mkdir -p /opt/cni/bin
mkdir -p /etc/cni/net.d

# Download and install standard CNI plugins
curl -fsSL https://github.com/containernetworking/plugins/releases/download/${CNI_PLUGIN_VERSION}/cni-plugins-linux-amd64-${CNI_PLUGIN_VERSION}.tgz -o /tmp/cni-plugins.tgz
tar -xzf /tmp/cni-plugins.tgz -C /opt/cni/bin

# Install Azure CNI by cloning and building from source
apt-get install -y git make gcc
cd /tmp
git clone --depth 1 --branch ${AZURE_CNI_VERSION} https://github.com/Azure/azure-container-networking.git
cd azure-container-networking
make azure-vnet
make azure-vnet-ipam
cp output/azure-vnet /opt/cni/bin/
cp output/azure-vnet-ipam /opt/cni/bin/
chmod +x /opt/cni/bin/azure-vnet*

echo "=== Step 7: Initialize Kubernetes control plane ==="
kubeadm init \
  --pod-network-cidr=10.244.0.0/16 \
  --service-cidr=10.96.0.0/16 \
  --apiserver-advertise-address=${CONTROL_PLANE_IP}

echo "=== Step 8: Configure kubectl for root and azureuser ==="
mkdir -p /root/.kube
cp -i /etc/kubernetes/admin.conf /root/.kube/config
chown root:root /root/.kube/config

mkdir -p /home/azureuser/.kube
cp -i /etc/kubernetes/admin.conf /home/azureuser/.kube/config
chown azureuser:azureuser /home/azureuser/.kube/config

export KUBECONFIG=/etc/kubernetes/admin.conf

echo "=== Step 9: Apply Azure CNI configuration ==="
# Create Azure CNI configuration for transparent mode (overlay)
cat > /etc/cni/net.d/10-azure.conflist <<'EOFCNI'
{
  "cniVersion": "0.3.1",
  "name": "azure",
  "plugins": [
    {
      "type": "azure-vnet",
      "mode": "transparent",
      "ipam": {
        "type": "host-local",
        "ranges": [[{"subnet": "10.244.0.0/16"}]],
        "routes": [{"dst": "0.0.0.0/0"}]
      }
    },
    {
      "type": "portmap",
      "capabilities": {"portMappings": true},
      "snat": true
    }
  ]
}
EOFCNI

echo "=== Step 10: Wait for CoreDNS to become ready ==="
kubectl wait --for=condition=ready pod -l k8s-app=kube-dns -n kube-system --timeout=300s || echo "CoreDNS not ready yet, continuing..."

echo "=== Step 11: Configure CoreDNS ==="
cat <<'EOFCOREDNS' | kubectl apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: coredns
  namespace: kube-system
data:
  Corefile: |
    .:53 {
        errors
        health {
           lameduck 5s
        }
        ready
        kubernetes cluster.local in-addr.arpa ip6.arpa {
           pods insecure
           fallthrough in-addr.arpa ip6.arpa
           ttl 30
        }
        prometheus :9153
        forward . 168.63.129.16
        cache 30
        loop
        reload
        loadbalance
    }
EOFCOREDNS

kubectl rollout restart deployment coredns -n kube-system
kubectl rollout status deployment coredns -n kube-system --timeout=120s

echo "=== Step 12: Install Azure CLI ==="
curl -sL https://aka.ms/InstallAzureCLIDeb | bash

echo "=== Step 13: Login to Azure using managed identity ==="
az login --identity

echo "=== Step 14: Wait for Key Vault permissions ==="
sleep 30

echo "=== Step 15: Store join command in Key Vault ==="
JOIN_COMMAND=$(kubeadm token create --print-join-command)
MAX_RETRIES=5
RETRY_COUNT=0

while [ $RETRY_COUNT -lt $MAX_RETRIES ]; do
  if az keyvault secret set --vault-name ${KEY_VAULT_NAME} --name "kubeadm-join-command" --value "$JOIN_COMMAND" 2>/dev/null; then
    echo "Join command successfully stored in Key Vault"
    break
  fi
  echo "Failed to store secret (attempt $((RETRY_COUNT+1))/$MAX_RETRIES). Retrying in 10 seconds..."
  sleep 10
  RETRY_COUNT=$((RETRY_COUNT+1))
done

if [ $RETRY_COUNT -eq $MAX_RETRIES ]; then
  echo "ERROR: Failed to store join command in Key Vault"
  echo "WARNING: Worker nodes will not be able to join automatically"
fi

echo "=== Master node setup completed ==="
