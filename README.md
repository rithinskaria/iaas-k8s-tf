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
# Minimal configuration
resource_group_name = "rg-k8s-prod"
location            = "eastus"
admin_username      = "azureuser"
ssh_public_key_path = "~/.ssh/id_rsa.pub"

# CNI Selection (optional, defaults to Cilium + Istio)
cni_type = 2  # 1 = Calico, 2 = Cilium + Istio

# Worker count (optional, default = 3)
worker_node_count = 3

# VM sizing (optional, defaults to Standard_D2s_v3)
vm_size = "Standard_D2s_v3"
```

**Advanced Configuration Example:**

```hcl
resource_group_name   = "rg-k8s-prod"
location              = "eastus"
vnet_address_prefix   = "10.0.0.0/16"
k8s_subnet_prefix     = "10.0.1.0/24"
bastion_subnet_prefix = "10.0.2.0/26"
admin_username        = "azureuser"
ssh_public_key_path   = "~/.ssh/k8s-azure-key.pub"
cni_type              = 2
worker_node_count     = 5
vm_size               = "Standard_D4s_v3"

tags = {
  environment = "production"
  project     = "k8s-infrastructure"
  owner       = "platform-team"
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

## Project Structure

```
iaas-k8s-tf/
├── main.tf                 # Main Terraform configuration
├── variables.tf            # Variable definitions
├── outputs.tf              # Output definitions
├── provider.tf             # Azure provider configuration
├── terraform.tfvars        # Your variable values (customize this)
├── modules/
│   ├── resource_group/     # Resource group module
│   ├── virtual_network/    # VNet and subnets
│   ├── network_security_group/ # NSG rules
│   ├── managed_identity/   # User-assigned identity
│   ├── key_vault/          # Key Vault for secrets
│   ├── bastion/            # Azure Bastion
│   ├── master_node/        # Kubernetes master VM
│   └── worker_vmss/        # Worker node VMSS
├── scripts/
│   ├── master-init.sh      # Master node initialization
│   └── worker-init.sh      # Worker node initialization
└── manifests/
    ├── ccm.yaml            # Cloud Controller Manager
    └── cnm.yaml            # Cloud Node Manager
```

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

### Required Variables

| Variable | Type | Description | Example |
|----------|------|-------------|----------|
| `resource_group_name` | string | Azure resource group | `"rg-k8s-prod"` |
| `location` | string | Azure region | `"eastus"` |
| `admin_username` | string | VM admin username | `"azureuser"` |
| `ssh_public_key_path` | string | Path to SSH public key | `"~/.ssh/id_rsa.pub"` |

### Optional Variables (with defaults)

| Variable | Type | Default | Description |
|----------|------|---------|-------------|
| `cni_type` | number | `2` | CNI choice: 1=Calico, 2=Cilium+Istio |
| `worker_node_count` | number | `3` | Number of worker nodes |
| `vm_size` | string | `"Standard_D2s_v3"` | Azure VM SKU |
| `vnet_address_prefix` | string | `"10.0.0.0/16"` | VNet CIDR |
| `k8s_subnet_prefix` | string | `"10.0.1.0/24"` | Kubernetes subnet CIDR |
| `bastion_subnet_prefix` | string | `"10.0.2.0/26"` | Bastion subnet CIDR |
| `os_disk_size_gb` | number | `30` | OS disk size |

### VM Sizing Recommendations

| Use Case | VM Size | vCPU | Memory | Cost/Month (East US) |
|----------|---------|------|--------|----------------------|
| **Development** | Standard_B2s | 2 | 4 GB | ~$30 |
| **Testing** | Standard_D2s_v3 | 2 | 8 GB | ~$70 |
| **Production** | Standard_D4s_v3 | 4 | 16 GB | ~$140 |
| **High Performance** | Standard_D8s_v3 | 8 | 32 GB | ~$280 |

## 🔧 Post-Deployment

### Deploy a Test Application

```bash
# Create a deployment
kubectl create deployment nginx --image=nginx --replicas=2

# Expose via LoadBalancer (creates Azure Load Balancer)
kubectl expose deployment nginx --type=LoadBalancer --port=80

# Get external IP
kubectl get svc nginx
```

### Verify Azure Integration

```bash
# Check Azure Load Balancer
az network lb list -g rg-k8s-dev-cc-13 -o table

# Check Azure Arc connection
az connectedk8s show --name arc-k8s-dev-cc-01 --resource-group rg-k8s-dev-cc-13

# View cloud controller logs
kubectl logs -n kube-system deployment/cloud-controller-manager
```

### Scale Worker Nodes

```bash
# Update worker_node_count in terraform.tfvars
worker_node_count = 5

# Apply changes
terraform apply
```

## Troubleshooting

### Workers Not Joining

1. Check Key Vault access:
```bash
az keyvault secret show --vault-name <vault-name> --name kubeadm-join-command
```

2. Check worker node logs:
```bash
# SSH to worker via Bastion
sudo journalctl -u kubelet -f
```

### Load Balancer Not Working

1. Verify cloud controller is running:
```bash
kubectl get pods -n kube-system -l component=cloud-controller-manager
kubectl logs -n kube-system deployment/cloud-controller-manager
```

2. Check service endpoints:
```bash
kubectl get endpoints <service-name>
kubectl describe svc <service-name>
```

### Calico Issues

```bash
# Check Calico pods
kubectl get pods -n calico-system

# View Calico logs
kubectl logs -n calico-system -l k8s-app=calico-node
```

## 🧹 Cleanup

```bash
# Destroy all resources
terraform destroy

# Confirm with 'yes'
```

## Additional Resources

- **Bicep Version**: [IaaS K8s Bicep Implementation](https://github.com/francisnazareth/iaas-k8s)
- [Azure Cloud Controller Manager](https://github.com/kubernetes-sigs/cloud-provider-azure)
- [Calico Documentation](https://docs.tigera.io/calico/latest/about/)
- [Azure Arc-enabled Kubernetes](https://learn.microsoft.com/azure/azure-arc/kubernetes/)
- [Kubernetes Documentation](https://kubernetes.io/docs/)

## Security Considerations

1. **SSH Keys**: Keep private key secure, never commit to git
2. **Bastion Access**: Only access VMs via Azure Bastion
3. **NSG Rules**: Review and restrict as needed
4. **RBAC**: Implement proper Kubernetes RBAC policies
5. **Key Vault**: Managed Identity authentication only

## Key Features

✅ **Full Azure Integration**: Load Balancers, Managed Disks, Node Management  
✅ **Production Ready**: Calico network policy, CoreDNS, proper taints/tolerations  
✅ **Scalable**: VMSS-based workers with auto-scaling support  
✅ **Secure**: Managed Identity, Key Vault, Bastion access  
✅ **Observable**: Azure Arc integration for monitoring  
✅ **Automated**: Single `terraform apply` deployment  

## Contributing

Contributions welcome! Please open an issue or submit a pull request.

## License

MIT License

## Authors

- [Rithin Skaria](https://github.com/rithinskaria)

- [Francis Nazareth](https://github.com/francisnazareth) (Bicep)
