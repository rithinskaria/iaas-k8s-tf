#!/bin/bash
CONTROL_PLANE_IP=$(hostname -I | awk '{print $1}')

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

# Initialize control plane with kubenet (pod CIDR for overlay network)
echo "=== Initializing Kubernetes control plane with kubenet ==="
kubeadm init --apiserver-advertise-address=$CONTROL_PLANE_IP --service-dns-domain=cluster.local --pod-network-cidr=10.244.0.0/16

# Configure kubeconfig for azureuser
mkdir -p /home/azureuser/.kube
cp -i /etc/kubernetes/admin.conf /home/azureuser/.kube/config
chown azureuser:azureuser /home/azureuser/.kube/config
export KUBECONFIG=/home/azureuser/.kube/config

echo "=== Installing Calico CNI for network policy ==="
kubectl create -f https://raw.githubusercontent.com/projectcalico/calico/v3.28.0/manifests/tigera-operator.yaml
sleep 10

# Create Calico custom resources with matching pod CIDR
cat <<EOFCALICO | kubectl apply -f -
apiVersion: operator.tigera.io/v1
kind: Installation
metadata:
  name: default
spec:
  calicoNetwork:
    ipPools:
    - blockSize: 26
      cidr: 10.244.0.0/16
      encapsulation: VXLAN
      natOutgoing: Enabled
      nodeSelector: all()
---
apiVersion: operator.tigera.io/v1
kind: APIServer
metadata:
  name: default
spec: {}
EOFCALICO

echo "=== Waiting for Calico to be ready ==="
kubectl wait --for=condition=ready pod -l k8s-app=calico-node -n calico-system --timeout=300s || echo "Calico not ready yet, continuing..."

echo "=== Removing taint from master node to allow pod scheduling ==="
kubectl taint nodes --all node-role.kubernetes.io/control-plane:NoSchedule- || echo "Taint already removed or not present"
kubectl taint nodes --all node-role.kubernetes.io/master:NoSchedule- || echo "Master taint already removed or not present"

echo "=== Waiting for CoreDNS to be ready ==="
kubectl wait --for=condition=ready pod -l k8s-app=kube-dns -n kube-system --timeout=300s || echo "CoreDNS not ready yet, continuing..."

echo "=== Configuring CoreDNS to forward to Azure DNS ==="
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

# Create Azure cloud config
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

# Create Kubernetes secret for Azure cloud config
echo "=== Creating Kubernetes secret for Azure cloud config ==="
kubectl --kubeconfig=/etc/kubernetes/admin.conf create secret generic azure-cloud-config \
  --from-file=cloud-config=/etc/kubernetes/azure.json \
  -n kube-system

# Create Azure Cloud Controller Manager manifest
echo "=== Creating Azure Cloud Controller Manager manifest ==="
cat > /tmp/ccm.yaml <<'EOFCCM'
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: cloud-controller-manager
  namespace: kube-system
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: system:cloud-controller-manager
  annotations:
    rbac.authorization.kubernetes.io/autoupdate: "true"
  labels:
    k8s-app: cloud-controller-manager
rules:
- apiGroups: [""]
  resources: ["events"]
  verbs: ["create", "patch", "update"]
- apiGroups: [""]
  resources: ["nodes"]
  verbs: ["*"]
- apiGroups: [""]
  resources: ["nodes/status"]
  verbs: ["patch"]
- apiGroups: [""]
  resources: ["services"]
  verbs: ["list", "patch", "update", "watch"]
- apiGroups: [""]
  resources: ["services/status"]
  verbs: ["list", "patch", "update", "watch"]
- apiGroups: [""]
  resources: ["serviceaccounts"]
  verbs: ["create", "get"]
- apiGroups: [""]
  resources: ["persistentvolumes"]
  verbs: ["get", "list", "update", "watch"]
- apiGroups: [""]
  resources: ["endpoints"]
  verbs: ["create", "get", "list", "watch", "update"]
- apiGroups: ["coordination.k8s.io"]
  resources: ["leases"]
  verbs: ["get", "create", "update"]
- apiGroups: [""]
  resources: ["secrets"]
  verbs: ["get", "list", "watch"]
- apiGroups: ["discovery.k8s.io"]
  resources: ["endpointslices"]
  verbs: ["get", "list", "watch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: system:cloud-controller-manager
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: system:cloud-controller-manager
subjects:
- kind: ServiceAccount
  name: cloud-controller-manager
  namespace: kube-system
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: cloud-controller-manager:apiserver-authentication-reader
  namespace: kube-system
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: extension-apiserver-authentication-reader
subjects:
- kind: ServiceAccount
  name: cloud-controller-manager
  namespace: kube-system
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: cloud-controller-manager
  namespace: kube-system
  labels:
    component: cloud-controller-manager
spec:
  replicas: 1
  selector:
    matchLabels:
      component: cloud-controller-manager
  template:
    metadata:
      labels:
        component: cloud-controller-manager
    spec:
      serviceAccountName: cloud-controller-manager
      priorityClassName: system-node-critical
      hostNetwork: true
      nodeSelector:
        node-role.kubernetes.io/control-plane: ""
      tolerations:
      - key: node-role.kubernetes.io/control-plane
        effect: NoSchedule
      - key: node-role.kubernetes.io/master
        effect: NoSchedule
      - key: node.cloudprovider.kubernetes.io/uninitialized
        value: "true"
        effect: NoSchedule
      - key: node.kubernetes.io/not-ready
        effect: NoSchedule
      containers:
      - name: cloud-controller-manager
        image: mcr.microsoft.com/oss/kubernetes/azure-cloud-controller-manager:v1.34.2
        imagePullPolicy: IfNotPresent
        command:
        - cloud-controller-manager
        - --cloud-provider=azure
        - --cluster-name=kubernetes
        - --controllers=*,-cloud-node
        - --cloud-config=/etc/kubernetes/azure.json
        - --configure-cloud-routes=false
        - --allocate-node-cidrs=false
        - --leader-elect=true
        - --route-reconciliation-period=10s
        - --v=2
        volumeMounts:
        - name: etc-kubernetes
          mountPath: /etc/kubernetes
          readOnly: true
        - name: cloud-config
          mountPath: /etc/kubernetes/azure.json
          subPath: cloud-config
          readOnly: true
      volumes:
      - name: etc-kubernetes
        hostPath:
          path: /etc/kubernetes
          type: DirectoryOrCreate
      - name: cloud-config
        secret:
          secretName: azure-cloud-config
EOFCCM

# Deploy Azure Cloud Controller Manager
echo "=== Deploying Azure Cloud Controller Manager ==="
kubectl apply -f /tmp/ccm.yaml

# Create Azure Cloud Node Manager manifest
echo "=== Creating Azure Cloud Node Manager manifest ==="
cat > /tmp/cnm.yaml <<'EOFCNM'
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: cloud-node-manager
  namespace: kube-system
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: cloud-node-manager
  labels:
    k8s-app: cloud-node-manager
rules:
- apiGroups: [""]
  resources: ["nodes"]
  verbs: ["get", "list", "patch", "update", "watch"]
- apiGroups: [""]
  resources: ["nodes/status"]
  verbs: ["patch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: cloud-node-manager
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: cloud-node-manager
subjects:
- kind: ServiceAccount
  name: cloud-node-manager
  namespace: kube-system
---
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: cloud-node-manager
  namespace: kube-system
  labels:
    component: cloud-node-manager
spec:
  selector:
    matchLabels:
      k8s-app: cloud-node-manager
  template:
    metadata:
      labels:
        k8s-app: cloud-node-manager
    spec:
      serviceAccountName: cloud-node-manager
      hostNetwork: true
      priorityClassName: system-node-critical
      nodeSelector:
        kubernetes.io/os: linux
      tolerations:
      - key: CriticalAddonsOnly
        operator: Exists
      - key: node-role.kubernetes.io/master
        effect: NoSchedule
      - key: node-role.kubernetes.io/control-plane
        effect: NoSchedule
      - key: node.cloudprovider.kubernetes.io/uninitialized
        value: "true"
        effect: NoSchedule
      - key: node.kubernetes.io/not-ready
        effect: NoSchedule
      containers:
      - name: cloud-node-manager
        image: mcr.microsoft.com/oss/kubernetes/azure-cloud-node-manager:v1.34.2
        imagePullPolicy: IfNotPresent
        command:
        - cloud-node-manager
        - --node-name=$(NODE_NAME)
        - --wait-routes=false
        - --v=2
        env:
        - name: NODE_NAME
          valueFrom:
            fieldRef:
              fieldPath: spec.nodeName
        volumeMounts:
        - name: cloud-config
          mountPath: /etc/kubernetes/azure.json
          subPath: cloud-config
          readOnly: true
      volumes:
      - name: cloud-config
        secret:
          secretName: azure-cloud-config
EOFCNM

# Deploy Azure Cloud Node Manager
echo "=== Deploying Azure Cloud Node Manager ==="
kubectl apply -f /tmp/cnm.yaml

# Wait for cloud controllers to be ready
echo "=== Waiting for cloud controllers to be ready ==="
kubectl wait --for=condition=ready pod -l component=cloud-controller-manager -n kube-system --timeout=180s || echo "CCM not ready yet, continuing..."
kubectl wait --for=condition=ready pod -l k8s-app=cloud-node-manager -n kube-system --timeout=180s || echo "CNM not ready yet, continuing..."

# Wait for Key Vault permissions
echo "=== Waiting for Key Vault permissions ==="
sleep 30

# Store join command in Key Vault
echo "=== Storing join command in Key Vault ==="
JOIN_COMMAND=$(kubeadm token create --print-join-command)
MAX_RETRIES=5
RETRY_COUNT=0
while [ $RETRY_COUNT -lt $MAX_RETRIES ]; do
  if az keyvault secret set --vault-name ${KEY_VAULT_NAME} --name "kubeadm-join-command" --value "$JOIN_COMMAND" 2>/dev/null; then
    echo "Join command successfully stored in Key Vault"
    break
  fi
  echo "Failed to store secret in Key Vault (attempt $((RETRY_COUNT+1))/$MAX_RETRIES). Retrying in 10 seconds..."
  sleep 10
  RETRY_COUNT=$((RETRY_COUNT+1))
done
if [ $RETRY_COUNT -eq $MAX_RETRIES ]; then
  echo "ERROR: Failed to store join command in Key Vault after $MAX_RETRIES attempts"
fi

# Onboard Kubernetes cluster to Azure Arc
echo "=== Onboarding Kubernetes cluster to Azure Arc ==="

# Get subscription ID and resource group
SUBSCRIPTION_ID=$(az account show --query id -o tsv)
RESOURCE_GROUP="${RESOURCE_GROUP_NAME}"
ARC_CLUSTER_NAME="${ARC_CLUSTER_NAME}"
LOCATION="${LOCATION}"

# Install required Azure CLI extensions
az extension add --name connectedk8s --yes
az extension add --name k8s-extension --yes

# Register required resource providers
az provider register --namespace Microsoft.Kubernetes --wait
az provider register --namespace Microsoft.KubernetesConfiguration --wait
az provider register --namespace Microsoft.ExtendedLocation --wait

echo "Connecting cluster to Azure Arc..."
# Connect the cluster to Azure Arc
az connectedk8s connect \
  --name "$ARC_CLUSTER_NAME" \
  --resource-group "$RESOURCE_GROUP" \
  --location "$LOCATION" \
  --tags "environment=dev" "project=k8s-arc" \
  --correlation-id "$(uuidgen)"

if [ $? -eq 0 ]; then
  echo "Successfully onboarded cluster to Azure Arc"
  
  # Verify the connection
  az connectedk8s show --name "$ARC_CLUSTER_NAME" --resource-group "$RESOURCE_GROUP" -o table
else
  echo "WARNING: Failed to onboard cluster to Azure Arc"
fi

echo "=== Master node setup completed ==="
