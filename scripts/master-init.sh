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

# Create kubeadm config with external cloud provider
echo "=== Creating kubeadm configuration ==="
cat <<EOFKUBEADM > /tmp/kubeadm-config.yaml
apiVersion: kubeadm.k8s.io/v1beta4
kind: InitConfiguration
nodeRegistration:
  kubeletExtraArgs:
    cloud-provider: "external"
---
apiVersion: kubeadm.k8s.io/v1beta4
kind: ClusterConfiguration
networking:
  podSubnet: "10.244.0.0/16"
  serviceSubnet: "10.96.0.0/12"
  dnsDomain: "cluster.local"
apiServer:
  extraArgs:
    cloud-provider: "external"
controllerManager:
  extraArgs:
    cloud-provider: "external"
EOFKUBEADM

# Initialize control plane
echo "=== Initializing Kubernetes control plane ==="
kubeadm init --config=/tmp/kubeadm-config.yaml --apiserver-advertise-address=$CONTROL_PLANE_IP

# Configure kubeconfig for root
mkdir -p /root/.kube
cp -i /etc/kubernetes/admin.conf /root/.kube/config
export KUBECONFIG=/root/.kube/config

# Configure kubeconfig for azureuser
mkdir -p /home/azureuser/.kube
cp -i /etc/kubernetes/admin.conf /home/azureuser/.kube/config
chown azureuser:azureuser /home/azureuser/.kube/config

echo "=== Installing Calico CNI ==="
kubectl create -f https://raw.githubusercontent.com/projectcalico/calico/v3.28.0/manifests/tigera-operator.yaml
sleep 10

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

kubectl wait --for=condition=ready pod -l k8s-app=calico-node -n calico-system --timeout=300s || echo "Calico not ready yet"

echo "=== Removing taints ==="
kubectl taint nodes --all node-role.kubernetes.io/control-plane:NoSchedule- || true
kubectl taint nodes --all node-role.kubernetes.io/master:NoSchedule- || true

kubectl wait --for=condition=ready pod -l k8s-app=kube-dns -n kube-system --timeout=300s || echo "CoreDNS not ready yet"

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

echo "=== Installing Azure CLI ==="
curl -sL https://aka.ms/InstallAzureCLIDeb | bash
az login --identity

AZURE_TENANT_ID=$(az account show --query tenantId -o tsv)
AZURE_SUBSCRIPTION_ID=$(az account show --query id -o tsv)

echo "=== Creating azure.json ==="
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

kubectl create secret generic azure-cloud-provider \
  --from-literal=cloud-config="$(cat /etc/kubernetes/azure.json)" \
  -n kube-system

echo "=== Deploying CCM ==="
kubectl apply -f - <<'EOFCCM'
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
  verbs: ["patch"]
- apiGroups: [""]
  resources: ["serviceaccounts"]
  verbs: ["create", "get", "list", "watch"]
- apiGroups: [""]
  resources: ["persistentvolumes"]
  verbs: ["get", "list", "update", "watch"]
- apiGroups: [""]
  resources: ["configmaps"]
  verbs: ["get", "list", "watch"]
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
      hostNetwork: true
      priorityClassName: system-node-critical
      nodeSelector:
        node-role.kubernetes.io/control-plane: ""
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
      containers:
      - name: cloud-controller-manager
        image: mcr.microsoft.com/oss/kubernetes/azure-cloud-controller-manager:v1.34.2
        command:
        - cloud-controller-manager
        - --allocate-node-cidrs=false
        - --cloud-config=/etc/kubernetes/azure.json
        - --cloud-provider=azure
        - --cluster-name=kubernetes
        - --configure-cloud-routes=false
        - --controllers=*,-cloud-node
        - --leader-elect=true
        - --v=2
        env:
        - name: AZURE_CREDENTIAL_FILE
          value: /etc/kubernetes/azure.json
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
      - name: cloud-config
        secret:
          secretName: azure-cloud-provider
EOFCCM

echo "=== Deploying CNM ==="
kubectl apply -f - <<'EOFCNM'
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
        - name: AZURE_CREDENTIAL_FILE
          value: /etc/kubernetes/azure.json
        volumeMounts:
        - name: etc-kubernetes
          mountPath: /etc/kubernetes
          readOnly: true
      volumes:
      - name: etc-kubernetes
        hostPath:
          path: /etc/kubernetes
EOFCNM

echo "=== Waiting for CCM and CNM to be ready ==="
kubectl wait --for=condition=ready pod -l component=cloud-controller-manager -n kube-system --timeout=300s || echo "CCM not ready, checking status..."
kubectl wait --for=condition=ready pod -l k8s-app=cloud-node-manager -n kube-system --timeout=300s || echo "CNM not ready, checking status..."

# Verify CCM/CNM are running
echo "=== Verifying CCM deployment ==="
kubectl get deployment cloud-controller-manager -n kube-system
kubectl get pods -l component=cloud-controller-manager -n kube-system

echo "=== Verifying CNM deployment ==="
kubectl get daemonset cloud-node-manager -n kube-system
kubectl get pods -l k8s-app=cloud-node-manager -n kube-system

# Wait for nodes to be ready with cloud provider labels
echo "=== Waiting for nodes to get cloud provider labels ==="
RETRY_COUNT=0
while [ $RETRY_COUNT -lt 30 ]; do
  if kubectl get nodes -o json | jq -e '.items[0].spec.providerID' > /dev/null 2>&1; then
    echo "Node has been labeled by cloud provider"
    kubectl get nodes -o wide
    break
  fi
  echo "Waiting for cloud provider to label nodes (attempt $((RETRY_COUNT+1))/30)..."
  sleep 10
  RETRY_COUNT=$((RETRY_COUNT+1))
done

echo "=== Storing join command in Key Vault ==="
sleep 60
JOIN_COMMAND=$(kubeadm token create --print-join-command)
RETRY_COUNT=0
while [ $RETRY_COUNT -lt 10 ]; do
  if az keyvault secret set --vault-name ${KEY_VAULT_NAME} --name "kubeadm-join-command" --value "$JOIN_COMMAND" 2>/dev/null; then
    echo "Join command stored"
    break
  fi
  echo "Retry $((RETRY_COUNT+1))/10..."
  sleep 15
  RETRY_COUNT=$((RETRY_COUNT+1))
done

echo "=== Azure Arc onboarding ==="
SUBSCRIPTION_ID=$(az account show --query id -o tsv)
az extension add --name connectedk8s --yes
az extension add --name k8s-extension --yes
az provider register --namespace Microsoft.Kubernetes --wait
az provider register --namespace Microsoft.KubernetesConfiguration --wait
az provider register --namespace Microsoft.ExtendedLocation --wait

az connectedk8s connect \
  --name "${ARC_CLUSTER_NAME}" \
  --resource-group "${RESOURCE_GROUP_NAME}" \
  --location "${LOCATION}" \
  --tags "environment=dev" \
  --correlation-id "$(uuidgen)" || echo "Arc failed"

echo "=== Master setup complete ==="
