# Azure Kubernetes Cluster with Cilium/Istio or Calico CNI

Production-ready Kubernetes cluster on Azure IaaS with flexible CNI options: **Cilium + Istio service mesh** or **Calico** networking.

## Overview

This project provides a fully automated, production-grade Kubernetes deployment on Azure using Terraform. It features:

- **Flexible CNI Options**: Switch between Calico (traditional CNI) or Cilium + Istio (modern service mesh) with a single variable
- **Azure-Native Integration**: Managed Identity, Key Vault, Cloud Controller Manager, Cloud Node Manager
- **Automated Scaling**: Self-refreshing join tokens enable true VMSS auto-scaling without manual intervention
- **High Availability Ready**: Multi-node architecture with external cloud provider mode
- **Security Hardened**: RBAC, network policies, managed identities, NSG rules
- **Azure Arc Ready**: Optional Arc enablement for unified management and GitOps

---

## Architecture Highlights

### Infrastructure
- **Control Plane**: Single master node (expandable to multi-master)
- **Worker Nodes**: Azure VMSS (3 instances default, auto-scalable)
- **Bastion**: Secure SSH access point
- **Networking**: Azure VNet with dedicated subnets, NSG security

### CNI Options

**Option 1: Calico (CNI_TYPE=1)**
- Traditional Kubernetes networking
- Tigera operator deployment
- VXLAN encapsulation
- NetworkPolicy support

**Option 2: Cilium + Istio (CNI_TYPE=2, Default)**
- Cilium CNI for advanced networking (eBPF-based)
- Istio service mesh for traffic management
- mTLS encryption between services
- Advanced observability (Hubble, Jaeger, Kiali)
- L7 network policies

### Key Features
- **Automated Join Token Refresh**: Cron job updates join command every 23 hours in Azure Key Vault
- **Zero-Configuration Worker Scaling**: New VMSS instances auto-join cluster via Key Vault
- **External Cloud Provider**: CCM manages LoadBalancers, CNM initializes nodes
- **Istio Ingress Gateway**: Production-ready ingress with LoadBalancer integration (CNI_TYPE=2)
- **Azure Arc Support**: Optional enablement for centralized management, GitOps, and Azure Policy

---

## Prerequisites

### Azure Requirements
- **Azure Subscription** with appropriate quotas
- **Azure CLI** installed and configured (`az login`)
- **Permissions**: Contributor role on subscription or resource group
- **Resource Quotas**: 4+ vCPUs, 2+ Public IPs, 1 Load Balancer

### Local Tools
- **Terraform** >= 1.0
- **kubectl** (for cluster access)
- **SSH key pair** for VM access

### Generate SSH Key

```bash
# Generate SSH key pair for Kubernetes nodes
ssh-keygen -t rsa -b 4096 -f k8s-azure-key -C "k8s-azure-deployment"

# Display public key to add to terraform.tfvars
cat k8s-azure-key.pub
```

### Azure Arc (Optional)

If you plan to enable Azure Arc after deployment:

```bash
az provider register --namespace Microsoft.Kubernetes
az provider register --namespace Microsoft.KubernetesConfiguration
az provider register --namespace Microsoft.ExtendedLocation

# Install Arc CLI extension
az extension add --name connectedk8s
```

---

## Quick Start

### 1. Clone the Repository

```bash
git clone https://github.com/rithinskaria/iaas-k8s-tf.git
cd iaas-k8s-tf
```

### 2. Configure Variables

Create `terraform.tfvars`:

```hcl
# Required variables
resource_group_name   = "rg-k8s-dev-cc-01"
vnet_name             = "vnet-k8s-dev-cc-01"
vnet_address_prefix   = "10.0.0.0/20"
k8s_subnet_name       = "snet-k8s"
k8s_subnet_prefix     = "10.0.0.0/21"
bastion_subnet_prefix = "10.0.8.0/26"
bastion_name          = "bastion-k8s-dev-cc-01"
admin_username        = "azureuser"
vm_size               = "Standard_D4ds_v5"
ssh_public_key        = "ssh-rsa AAAAB3NzaC1yc2E... your-key-here"

# Optional: CNI Selection (defaults to 2 = Cilium + Istio)
cni_type = 2  # 1 = Calico, 2 = Cilium + Istio

# Optional: Worker count (defaults to 2)
worker_node_count = 3

# Optional: Additional settings with defaults
location            = "eastus"              # default: eastus
bastion_sku_name    = "Standard"           # default: Standard
key_vault_base_name = "kv-k8s-dev-cc"      # default: kv-k8s-dev-cc
arc_cluster_name    = "arc-k8s-dev-cc-01"  # default: arc-k8s-cluster
os_disk_size_gb     = 128                  # default: 128

tags = {
  environment = "dev"
  project     = "containers-infra"
}
```

**Production Configuration Example:**

```hcl
resource_group_name   = "rg-k8s-prod"
vnet_name             = "vnet-k8s-prod"
vnet_address_prefix   = "10.1.0.0/16"
k8s_subnet_name       = "snet-k8s-nodes"
k8s_subnet_prefix     = "10.1.0.0/21"
bastion_subnet_prefix = "10.1.8.0/26"
bastion_name          = "bastion-k8s-prod"
admin_username        = "azureuser"
vm_size               = "Standard_D8ds_v5"  # 8 vCPU, 32 GB RAM
ssh_public_key        = "ssh-rsa AAAAB3NzaC1yc2E... your-key-here"
location              = "eastus"
cni_type              = 2  # Cilium + Istio for advanced features
worker_node_count     = 5  # 5 worker nodes
os_disk_size_gb       = 256

tags = {
  environment = "production"
  project     = "k8s-infrastructure"
  owner       = "platform-team"
  costcenter  = "engineering"
}
```

### 3. Deploy Infrastructure

```bash
# Initialize Terraform
terraform init

# Review plan
terraform plan -out=tfplan

# Deploy (takes 15-25 minutes)
terraform apply tfplan
```

**Terraform will output:**
- Bastion public IP
- Master node private IP
- Key Vault name
- Resource group name

### 4. Access Cluster

```bash
# SSH to bastion (get IP from Terraform output)
ssh azureuser@<BASTION_PUBLIC_IP>

# From bastion, SSH to master
ssh 10.0.1.4

# Verify cluster
kubectl get nodes -o wide
# Expected: master + 3 workers, all Ready

# Check CNI pods
kubectl get pods -n kube-system  # Calico or Cilium
kubectl get pods -n istio-system # If CNI_TYPE=2

# Copy kubeconfig to local machine (from bastion)
scp azureuser@10.0.1.4:/home/azureuser/.kube/config ~/.kube/config
```

### 5. Verify Deployment

**If using Cilium + Istio (CNI_TYPE=2):**

```bash
# Scale Istio ingress gateway (starts at 0 replicas)
kubectl scale deployment istio-ingressgateway -n istio-system --replicas=3

# Verify gateway
kubectl get pods -n istio-system -l app=istio-ingressgateway
kubectl get svc istio-ingressgateway -n istio-system
# EXTERNAL-IP should show Azure LoadBalancer IP
```

**Deploy test application:**

```bash
# Create namespace with Istio injection (if CNI_TYPE=2)
kubectl create namespace demo
kubectl label namespace demo istio-injection=enabled  # CNI_TYPE=2 only

# Deploy nginx
kubectl create deployment nginx --image=nginx --replicas=2 -n demo
kubectl expose deployment nginx --type=LoadBalancer --port=80 -n demo

# Get external IP
kubectl get svc nginx -n demo
```

---

## What Gets Deployed

### Azure Infrastructure

| Resource | Configuration | Purpose |
|----------|--------------|----------|
| **Resource Group** | Single RG | Container for all resources |
| **Virtual Network** | 10.0.0.0/16 (default) | Network isolation |
| **Subnets** | K8s: 10.0.1.0/24, Bastion: 10.0.2.0/26 | Network segmentation |
| **Network Security Group** | Master/Worker/Bastion rules | Traffic control |
| **Key Vault** | Standard SKU | Secure join token storage |
| **Managed Identity** | User-assigned | Azure authentication |
| **Master VM** | 1x Standard_D2s_v3 | Kubernetes control plane |
| **Worker VMSS** | 3x Standard_D2s_v3 (default) | Scalable worker pool |
| **Bastion** | Standard SKU | Secure SSH access |
| **Load Balancer** | Standard SKU | Service ingress (auto-created) |

### Kubernetes Components

**Core (All Deployments):**
- Kubernetes v1.34.0
- kubeadm cluster bootstrap
- containerd runtime
- Azure Cloud Controller Manager (CCM) v1.34.2
- Azure Cloud Node Manager (CNM) v1.34.2
- CoreDNS with Azure DNS integration

**CNI Option 1 (cni_type=1):**
- Calico v3.28.0 (Tigera operator)
- VXLAN encapsulation
- NetworkPolicy support

**CNI Option 2 (cni_type=2, Default):**
- Cilium v1.16.5 (Helm chart)
- Istio v1.28.0 service mesh
- Istiod on master node
- Istio Ingress Gateway (0 initial replicas, scale to 3)
- mTLS between services
- Hubble network observability

**Optional (Post-Deployment):**
- Azure Arc agents (manual enablement)
- Prometheus + Grafana (manual deployment)
- Azure Monitor Container Insights (via Arc)

---

## Project Structure

```
iaas-k8s-tf/
├── main.tf                      # Root module orchestration
├── variables.tf                 # Input variable definitions
├── outputs.tf                   # Output definitions
├── provider.tf                  # Azure provider configuration
├── terraform.tfvars             # User configuration (create this)
├── modules/
│   ├── resource_group/          # Azure resource group
│   ├── virtual_network/         # VNet and subnets
│   ├── network_security_group/  # NSG rules
│   ├── managed_identity/        # User-assigned managed identity
│   ├── key_vault/               # Azure Key Vault for join tokens
│   ├── bastion/                 # Bastion host VM
│   ├── master_node/             # Kubernetes master VM
│   └── worker_vmss/             # Worker node VMSS
├── scripts/
│   ├── master-init.sh           # Master initialization (540 lines)
│   └── worker-init.sh           # Worker initialization (176 lines)
├── manifests/
│   ├── ccm.yaml                 # Cloud Controller Manager
│   └── cnm.yaml                 # Cloud Node Manager
└── docs/                        # Comprehensive documentation
    ├── ARCHITECTURE.md          # System architecture and design
    ├── PREREQUISITES.md         # Detailed prerequisites
    ├── CONFIGURATION.md         # All Terraform variables
    ├── DEPLOYMENT.md            # Step-by-step deployment
    ├── MASTER_INIT.md           # Master node deep dive
    ├── WORKER_INIT.md           # Worker node deep dive
    ├── CNI_GUIDE.md             # Calico vs Cilium+Istio
    ├── ISTIO_GUIDE.md           # Service mesh configuration
    ├── OPERATIONS.md            # Day-2 operations
    ├── SCALING.md               # Scaling and maintenance
    ├── TROUBLESHOOTING.md       # Common issues and solutions
    ├── AZURE_INTEGRATION.md     # Managed Identity, Key Vault, CCM/CNM
    ├── SECURITY.md              # RBAC, pod security, network policies
    ├── MONITORING.md            # Observability and monitoring
    └── ARC_ENABLEMENT.md        # Azure Arc setup and GitOps
```

---

## Cost Estimation

**Monthly Azure costs** (default configuration with `cni_type=2`, East US region):

| Resource | SKU | Count | Monthly Cost |
|----------|-----|-------|---------------|
| Master VM | Standard_D4ds_v5 | 1 | ~$175 |
| Worker VMs | Standard_D4ds_v5 | 2 (default) | ~$350 |
| Bastion VM | Standard_B2s | 1 | ~$30 |
| Storage (Premium SSD) | 128GB OS disks | 3 total | ~$60 |
| Azure Bastion | Standard SKU | 1 | ~$145 |
| VNet, NSG | Standard | - | ~$0 (no charge) |
| Public IPs | Standard | 1 | ~$4 |
| Key Vault | Standard | 1 | ~$0.50 |
| Load Balancer | Standard (auto-created) | 1 | ~$18 |
| Bandwidth (outbound) | Variable | - | ~$5-20 |
| **Base Infrastructure** | | | **~$787-802/month** |

**With 3 workers** (as shown in examples): **~$962-977/month**

**Optional Costs:**

| Component | Monthly Cost | Notes |
|-----------|--------------|-------|
| Azure Arc (core) | FREE | Cluster connection, inventory, GitOps (<10 configs) |
| Azure Monitor Container Insights | ~$25 | ~10GB logs/month |
| Azure Defender for Kubernetes | ~$60 | ~8 vCPUs × $0.02/core/hour |
| Azure Backup (etcd) | ~$5 | Backup storage |

**Total with Arc + Monitoring: ~$373-438/month**

**Cost Optimization Tips:**
- Use Azure Reservations (1-3 year commitment) for 40-60% savings
- Use Spot VMs for non-production workloads
- Scale down workers during off-hours
- Use Standard HDD for non-critical workloads
- Implement pod autoscaling to optimize resource usage

---

## Security Features

### Infrastructure Security
- ✅ **No Service Principals**: Uses Azure Managed Identity (no credentials stored)
- ✅ **Key Vault Integration**: Join tokens stored securely, auto-rotated every 23 hours
- ✅ **Network Segmentation**: NSG rules restrict traffic between subnets
- ✅ **Bastion Access**: No direct SSH exposure, all access via Azure Bastion
- ✅ **Private Network**: All cluster communication on private IPs

### Kubernetes Security
- ✅ **RBAC Enabled**: Role-based access control by default
- ✅ **Node Taints**: Master node tainted to prevent workload scheduling
- ✅ **Pod Security Standards**: Enforced in namespaces
- ✅ **NetworkPolicy**: Available with both CNI options
- ✅ **External Cloud Provider**: Minimal kubelet permissions

### Service Mesh Security (CNI_TYPE=2)
- ✅ **mTLS**: Automatic mutual TLS between services
- ✅ **AuthorizationPolicy**: Fine-grained access control
- ✅ **JWT Authentication**: Support for external IdP
- ✅ **Certificate Rotation**: Automatic via Istio CA

### Best Practices Implemented
1. **Secrets Management**: Azure Key Vault for sensitive data
2. **Least Privilege**: Managed identity with minimum required permissions
3. **Immutable Infrastructure**: Terraform-managed, version-controlled
4. **Automated Updates**: Join token refresh, CNI updates via Helm
5. **Audit Logging**: Available via Azure Arc and Azure Monitor

---

## Key Technologies

| Component | Version | Purpose |
|-----------|---------|----------|
| **Kubernetes** | v1.34.0 | Container orchestration |
| **kubeadm** | v1.34.0 | Cluster bootstrapping |
| **containerd** | v1.7.x | Container runtime |
| **Calico** | v3.28.0 | CNI Option 1: Traditional networking |
| **Cilium** | v1.16.5 | CNI Option 2: eBPF-based networking |
| **Istio** | v1.28.0 | Service mesh (with Cilium) |
| **Azure CCM** | v1.34.2 | Cloud Controller Manager |
| **Azure CNM** | v1.34.2 | Cloud Node Manager |

---

## CNI Selection Guide

### When to Use Calico (cni_type=1)

✅ **Best For:**
- Traditional Kubernetes networking requirements
- BGP routing preferred (customizable)
- Simpler troubleshooting with mature tooling
- Lower resource overhead (~200MB memory)
- Well-established in existing infrastructure

**Features:**
- NetworkPolicy support
- VXLAN or IPIP encapsulation
- GlobalNetworkPolicy (cluster-wide)
- Calico Typha for large clusters

### When to Use Cilium + Istio (cni_type=2, Default)

✅ **Best For:**
- Advanced traffic management (canary, A/B testing)
- Service mesh capabilities (mTLS, retries, circuit breaking)
- Enhanced observability (distributed tracing, service graphs)
- L7 network policies (HTTP method/path filtering)
- Modern eBPF-based networking for performance

**Features:**
- eBPF datapath (lower CPU, higher throughput)
- Istio service mesh integration
- Hubble network observability
- L7-aware NetworkPolicy
- mTLS encryption between services
- Distributed tracing (Jaeger)
- Service graph visualization (Kiali)

**Resource Requirements:**
- ~500MB additional memory (Cilium + Istio)
- ~0.5 CPU cores (istiod + ingress gateway)

### Switching CNIs

⚠️ **CNI switching requires cluster recreation** (not in-place migration):

```bash
# Change cni_type in terraform.tfvars
cni_type = 1  # or 2

# Destroy and recreate
terraform destroy
terraform apply
```

---

## Configuration Variables

### Required Variables (no defaults)

| Variable | Type | Description | Example |
|----------|------|-------------|----------|
| `resource_group_name` | string | Azure resource group name | `"rg-k8s-prod"` |
| `vnet_name` | string | Virtual network name | `"vnet-k8s-prod"` |
| `vnet_address_prefix` | string | VNet CIDR block | `"10.0.0.0/20"` |
| `k8s_subnet_name` | string | Kubernetes subnet name | `"snet-k8s"` |
| `k8s_subnet_prefix` | string | Kubernetes subnet CIDR | `"10.0.0.0/21"` |
| `bastion_subnet_prefix` | string | Bastion subnet CIDR | `"10.0.8.0/26"` |
| `bastion_name` | string | Bastion host name | `"bastion-k8s-prod"` |
| `admin_username` | string | VM admin username | `"azureuser"` |
| `vm_size` | string | Azure VM SKU | `"Standard_D4ds_v5"` |
| `ssh_public_key` | string (sensitive) | SSH public key content | `"ssh-rsa AAAAB3..."` |

### Optional Variables (with defaults)

| Variable | Type | Default | Validation | Description |
|----------|------|---------|------------|-------------|
| `location` | string | `"eastus"` | - | Azure region |
| `cni_type` | number | `2` | 1 or 2 | CNI choice: 1=Calico, 2=Cilium+Istio |
| `worker_node_count` | number | `2` | 1-10 | Number of worker nodes in VMSS |
| `bastion_sku_name` | string | `"Standard"` | Basic/Standard/Premium | Azure Bastion SKU |
| `key_vault_base_name` | string | `"kv-k8s-dev-cc"` | - | Base name for Key Vault (random suffix added) |
| `arc_cluster_name` | string | `"arc-k8s-cluster"` | - | Name for Arc-enabled cluster registration |
| `os_disk_size_gb` | number | `128` | 30-2048 | OS disk size in GB |
| `tags` | map(string) | `{}` | - | Tags to apply to all resources |

### VM Sizing Recommendations

| Use Case | VM Size | vCPU | Memory | Cost/Month (East US)* |
|----------|---------|------|--------|----------------------|
| **Development** | Standard_D2ds_v5 | 2 | 8 GB | ~$88 |
| **Testing/Default** | Standard_D4ds_v5 | 4 | 16 GB | ~$175 |
| **Production** | Standard_D8ds_v5 | 8 | 32 GB | ~$350 |
| **High Performance** | Standard_D16ds_v5 | 16 | 64 GB | ~$700 |

*Prices are approximate pay-as-you-go rates. Use Azure Pricing Calculator for exact costs.

**CNI Resource Impact:**
- **Calico (cni_type=1)**: ~200MB memory per node
- **Cilium + Istio (cni_type=2)**: ~500MB memory per node (Cilium) + 1GB on master (Istiod)

---

## Post-Deployment Operations

### Deploy Test Application

**Simple LoadBalancer Service:**

```bash
kubectl create deployment nginx --image=nginx --replicas=2
kubectl expose deployment nginx --type=LoadBalancer --port=80

# Wait for external IP (takes 2-3 minutes)
kubectl get svc nginx --watch

# Test
curl http://<EXTERNAL-IP>
```

**Istio Gateway (CNI_TYPE=2):**

```bash
# Create namespace with sidecar injection
kubectl create namespace demo
kubectl label namespace demo istio-injection=enabled

# Deploy httpbin
kubectl apply -n demo -f https://raw.githubusercontent.com/istio/istio/release-1.28/samples/httpbin/httpbin.yaml

# Create Gateway and VirtualService
cat <<EOF | kubectl apply -f -
apiVersion: networking.istio.io/v1beta1
kind: Gateway
metadata:
  name: httpbin-gateway
  namespace: demo
spec:
  selector:
    istio: ingressgateway
  servers:
  - port:
      number: 80
      name: http
      protocol: HTTP
    hosts:
    - "*"
---
apiVersion: networking.istio.io/v1beta1
kind: VirtualService
metadata:
  name: httpbin
  namespace: demo
spec:
  hosts:
  - "*"
  gateways:
  - httpbin-gateway
  http:
  - route:
    - destination:
        host: httpbin
        port:
          number: 8000
EOF

# Get ingress IP
kubectl get svc istio-ingressgateway -n istio-system

# Test
curl http://<INGRESS-IP>/headers
```

### Scale Worker Nodes

**Via Azure CLI:**

```bash
az vmss scale \
  --resource-group <RESOURCE_GROUP> \
  --name <VMSS_NAME> \
  --new-capacity 5

# New instances automatically join cluster (via Key Vault join token)
```

**Via Terraform:**

```bash
# Update terraform.tfvars
worker_node_count = 5

# Apply
terraform apply
```

**Verify new nodes:**

```bash
kubectl get nodes
# Should show 1 master + 5 workers

kubectl get pods -n kube-system -o wide
# CNI pods should be running on all nodes
```

### Enable Azure Arc

Arc enablement is **optional** and performed after cluster deployment.

**Prerequisites:**

```bash
# Register providers (one-time)
az provider register --namespace Microsoft.Kubernetes
az provider register --namespace Microsoft.KubernetesConfiguration
az provider register --namespace Microsoft.ExtendedLocation

# Install Arc CLI extension
az extension add --name connectedk8s
az extension update --name connectedk8s
```

**Connect cluster to Arc:**

```bash
# SSH to master node
ssh azureuser@<BASTION_IP>
ssh 10.0.1.4

# Login with managed identity
az login --identity

# Connect to Arc
RESOURCE_GROUP="rg-k8s-prod"
CLUSTER_NAME="k8s-iaas-cluster"
LOCATION="eastus"

az connectedk8s connect \
  --name "$CLUSTER_NAME" \
  --resource-group "$RESOURCE_GROUP" \
  --location "$LOCATION" \
  --tags environment=production cni_type=cilium

# Verify Arc pods
kubectl get pods -n azure-arc

# Check Arc status
az connectedk8s show \
  --name "$CLUSTER_NAME" \
  --resource-group "$RESOURCE_GROUP" \
  --query "{Name:name, Status:connectivityStatus, K8sVersion:kubernetesVersion}"
```

**Arc Benefits:**
- Unified management in Azure Portal
- GitOps with Flux v2
- Azure Policy enforcement
- Azure Monitor Container Insights
- Centralized RBAC with Azure AD

**See detailed Arc documentation in `docs/ARC_ENABLEMENT.md`**

### Monitoring

**Basic monitoring (kubectl):**

```bash
# Node resource usage
kubectl top nodes

# Pod resource usage
kubectl top pods --all-namespaces

# View logs
kubectl logs -n kube-system -l component=cloud-controller-manager --tail=100
```

**Istio observability (CNI_TYPE=2):**

```bash
# Install Grafana
kubectl apply -f https://raw.githubusercontent.com/istio/istio/release-1.28/samples/addons/grafana.yaml

# Port-forward
kubectl port-forward -n istio-system svc/grafana 3000:3000
# Open http://localhost:3000

# Install Kiali (service graph)
kubectl apply -f https://raw.githubusercontent.com/istio/istio/release-1.28/samples/addons/kiali.yaml
kubectl port-forward -n istio-system svc/kiali 20001:20001
# Open http://localhost:20001
```

---

## Troubleshooting

### Cluster Not Accessible

**Check master VM:**

```bash
# From Azure CLI
az vm get-instance-view \
  --resource-group <RESOURCE_GROUP> \
  --name <MASTER_VM> \
  --query instanceView.statuses

# SSH to master (via bastion)
ssh azureuser@<BASTION_IP>
ssh 10.0.1.4

# Check kubelet
sudo systemctl status kubelet
sudo journalctl -u kubelet -f

# Check pods
kubectl get pods -A
kubectl get nodes
```

### Workers Not Joining

**Verify join token in Key Vault:**

```bash
az keyvault secret show \
  --vault-name <KEY_VAULT_NAME> \
  --name kubeadm-join-command \
  --query value -o tsv
```

**Check worker logs:**

```bash
# SSH to worker (via bastion)
ssh azureuser@<BASTION_IP>
ssh 10.0.2.4  # First worker

# Check kubelet
sudo journalctl -u kubelet -f

# Check managed identity
az login --identity
az account show

# Test Key Vault access
az keyvault secret list --vault-name <KEY_VAULT_NAME>
```

**Common issues:**
- Token expired (auto-refreshed every 23 hours, check cron on master)
- Managed identity permissions missing
- Network connectivity to master:6443

### Pods Stuck Pending

```bash
# Describe pod to see reason
kubectl describe pod <POD_NAME> -n <NAMESPACE>

# Common reasons:
# 1. Insufficient resources
kubectl top nodes
kubectl describe nodes | grep -A 5 "Allocated resources"

# 2. Node taint/affinity mismatch
kubectl get nodes -o json | jq '.items[].spec.taints'

# 3. Image pull errors
kubectl get events --field-selector type=Warning --all-namespaces
```

### CNI Issues

**Calico (CNI_TYPE=1):**

```bash
# Check Calico pods
kubectl get pods -n kube-system -l k8s-app=calico-node
kubectl get pods -n kube-system -l k8s-app=calico-kube-controllers

# Check Calico logs
kubectl logs -n kube-system -l k8s-app=calico-node --tail=100

# Verify VXLAN interface (on node)
ip link show vxlan.calico
```

**Cilium (CNI_TYPE=2):**

```bash
# Check Cilium pods
kubectl get pods -n kube-system -l k8s-app=cilium

# Cilium status (from Cilium pod)
kubectl exec -n kube-system ds/cilium -- cilium status

# Check connectivity
kubectl exec -n kube-system ds/cilium -- cilium-health status

# View logs
kubectl logs -n kube-system -l k8s-app=cilium --tail=100
```

**Istio (CNI_TYPE=2):**

```bash
# Check Istio pods
kubectl get pods -n istio-system

# Istiod logs
kubectl logs -n istio-system -l app=istiod --tail=100

# Ingress gateway not getting external IP
kubectl describe svc istio-ingressgateway -n istio-system
# Check: Azure CCM logs for LoadBalancer creation
kubectl logs -n kube-system deployment/cloud-controller-manager --tail=100
```

### LoadBalancer Stuck in Pending

```bash
# Check service
kubectl describe svc <SERVICE_NAME>

# Check CCM logs
kubectl logs -n kube-system deployment/cloud-controller-manager --tail=100

# Common issues:
# - CCM not running
kubectl get pods -n kube-system -l component=cloud-controller-manager

# - Managed identity permissions
# - Azure subscription quota (Public IPs, Load Balancers)

# Verify in Azure
az network lb list --resource-group <RESOURCE_GROUP> -o table
az network public-ip list --resource-group <RESOURCE_GROUP> -o table
```

### Join Token Refresh Not Working

```bash
# Check cron job (on master)
ssh 10.0.1.4
crontab -l | grep refresh-join-token

# Check logs
sudo cat /var/log/join-token-refresh.log

# Manually refresh
sudo /usr/local/bin/refresh-join-token.sh

# Verify token in Key Vault
az keyvault secret show \
  --vault-name <KEY_VAULT_NAME> \
  --name kubeadm-join-command \
  --query value -o tsv
```

---

## Cleanup

### Destroy Infrastructure

```bash
# Disconnect from Arc (if enabled)
az connectedk8s delete \
  --name <CLUSTER_NAME> \
  --resource-group <RESOURCE_GROUP> \
  --yes

# Destroy all Terraform-managed resources
terraform destroy

# Confirm with 'yes'
```

**Manual cleanup (if needed):**

```bash
# Delete any manually created LoadBalancers
az network lb list --resource-group <RESOURCE_GROUP>
az network lb delete --resource-group <RESOURCE_GROUP> --name <LB_NAME>

# Delete any manually created Public IPs
az network public-ip list --resource-group <RESOURCE_GROUP>
az network public-ip delete --resource-group <RESOURCE_GROUP> --name <IP_NAME>
```

---

## Key Features Summary

✅ **Flexible CNI**: Switch between Calico and Cilium+Istio with single variable  
✅ **Azure-Native**: Full CCM/CNM integration for LoadBalancer and node management  
✅ **Auto-Scaling**: Automated join token refresh enables zero-touch VMSS scaling  
✅ **Secure**: Managed Identity, Key Vault, Bastion access, NSG rules  
✅ **Observable**: Istio telemetry, Hubble, Azure Monitor ready  
✅ **GitOps Ready**: Optional Azure Arc enablement for Flux v2  
✅ **Production Grade**: External cloud provider, proper taints/tolerations  
✅ **Well Documented**: 15 comprehensive documentation files  

---

## Documentation

Comprehensive documentation available in `docs/` folder:

**Getting Started:**
- `PREREQUISITES.md` - Azure requirements, quotas, tools, permissions
- `CONFIGURATION.md` - All Terraform variables, examples, validation
- `DEPLOYMENT.md` - Step-by-step deployment guide

**Architecture:**
- `ARCHITECTURE.md` - System design, component diagrams, network topology
- `MASTER_INIT.md` - Deep dive into master-init.sh (540 lines)
- `WORKER_INIT.md` - Worker initialization and join process

**Networking & Service Mesh:**
- `CNI_GUIDE.md` - Calico vs Cilium+Istio comparison, NetworkPolicy examples
- `ISTIO_GUIDE.md` - Traffic management, security, observability

**Operations:**
- `OPERATIONS.md` - Day-2 operations, testing, monitoring
- `SCALING.md` - VMSS scaling, token refresh automation, upgrades
- `TROUBLESHOOTING.md` - Common issues, debug commands, solutions

**Security & Integration:**
- `AZURE_INTEGRATION.md` - Managed Identity, Key Vault, CCM, CNM, azure.json
- `SECURITY.md` - RBAC, pod security, managed identity, NetworkPolicy
- `MONITORING.md` - kubectl commands, logs, Istio/Cilium/Calico monitoring
- `ARC_ENABLEMENT.md` - Azure Arc setup, GitOps, Azure Policy, Container Insights

---

## Additional Resources

### Official Documentation
- [Kubernetes Documentation](https://kubernetes.io/docs/)
- [Calico Documentation](https://docs.tigera.io/calico/latest/)
- [Cilium Documentation](https://docs.cilium.io/)
- [Istio Documentation](https://istio.io/latest/docs/)
- [Azure Arc-enabled Kubernetes](https://learn.microsoft.com/azure/azure-arc/kubernetes/)
- [Azure Cloud Controller Manager](https://github.com/kubernetes-sigs/cloud-provider-azure)

### Related Projects
- **Bicep Version**: [IaaS K8s Bicep Implementation](https://github.com/francisnazareth/iaas-k8s)

### Community
- [Kubernetes Slack](https://kubernetes.slack.com/)
- [Istio Slack](https://istio.slack.com/)
- [Cilium Slack](https://cilium.slack.com/)

---

## Contributing

Contributions welcome! Please:

1. **Bug Reports**: Open issue with Terraform version, logs, steps to reproduce
2. **Feature Requests**: Describe use case, expected behavior
3. **Pull Requests**: 
   - Update documentation if changing behavior
   - Test with both `cni_type=1` and `cni_type=2`
   - Follow existing code style

---

## License

MIT License

---

## Authors

- **Rithin Skaria** - [GitHub](https://github.com/rithinskaria)
- **Francis Nazareth** - [GitHub](https://github.com/francisnazareth) (Original Bicep implementation)

---

## Acknowledgments

- **Kubernetes Community**: kubeadm, kubelet, kubectl
- **Calico/Tigera**: Calico CNI and operator
- **Cilium**: eBPF-based CNI
- **Istio**: Service mesh platform
- **Microsoft Azure**: Cloud platform and Kubernetes integration
- **Terraform**: Infrastructure as Code

---

**Ready to deploy?** Start with the Quick Start section above or read `docs/PREREQUISITES.md` for detailed requirements.
