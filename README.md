# [In-development - Do not use this]

# Kubernetes IaaS on Azure with Terraform

This project deploys a fully functional Kubernetes cluster on Azure VMs using Terraform, complete with Azure Cloud Controller Manager (CCM), Cloud Node Manager (CNM), Calico CNI, and Azure Arc integration.

## Architecture

- **Control Plane**: Single master node on Azure VM (Standard_D4ds_v5)
- **Worker Nodes**: Azure VMSS with configurable instance count
- **Networking**: Calico CNI with VXLAN encapsulation
- **Cloud Provider**: Azure CCM/CNM for load balancer and node lifecycle management
- **Monitoring**: Azure Arc-enabled Kubernetes for centralized management
- **Storage**: Azure Managed Disks via CSI drivers (optional)

## Prerequisites

- Azure subscription with Contributor access
- Azure CLI installed and configured (`az login`)
- Terraform >= 1.0
- SSH key pair for VM access

### Required Azure Resource Providers

Register the following Azure resource providers for Azure Arc-enabled Kubernetes:

```bash
az provider register --namespace Microsoft.Kubernetes
az provider register --namespace Microsoft.KubernetesConfiguration
az provider register --namespace Microsoft.ExtendedLocation
```

Verify registration status:
```bash
az provider show -n Microsoft.Kubernetes --query "registrationState"
az provider show -n Microsoft.KubernetesConfiguration --query "registrationState"
az provider show -n Microsoft.ExtendedLocation --query "registrationState"
```

## Generate SSH Key

```bash
# Generate SSH key pair for Kubernetes nodes
ssh-keygen -t rsa -b 4096 -f k8s-azure-key -C "k8s-azure-deployment"

# Display public key to add to terraform.tfvars
cat k8s-azure-key.pub
```

## Quick Start

### 1. Clone the Repository

```bash
git clone https://github.com/rithinskaria/iaas-k8s-tf.git
cd iaas-k8s-tf
```

### 2. Configure Variables

Create or update `terraform.tfvars`:

```hcl
location            = "canadacentral"
resource_group_name = "rg-k8s-dev-cc-13"
vnet_name           = "vnet-k8s-dev-cc-01"
vnet_address_prefix = "10.0.0.0/20"
k8s_subnet_name     = "snet-k8s"
k8s_subnet_prefix   = "10.0.0.0/21"
bastion_subnet_prefix = "10.0.8.0/26"
bastion_name        = "bastion-k8s-dev-cc-01"
bastion_sku_name    = "Standard"
key_vault_base_name = "kv-k8s-dev-cc"
arc_cluster_name    = "arc-k8s-dev-cc-01"
admin_username      = "azureuser"
vm_size             = "Standard_D4ds_v5"
worker_node_count   = 3
os_disk_size_gb     = 128

# Paste your SSH public key here
ssh_public_key = "ssh-rsa AAAAB3NzaC1yc2E... k8s-azure-deployment"

tags = {
  environment = "dev"
  project     = "containers-infra"
}
```

### 3. Deploy Infrastructure

```bash
# Initialize Terraform
terraform init

# Review the plan
terraform plan

# Deploy infrastructure
terraform apply
```

### 4. Access the Cluster

```bash
# Connect to master node via Azure Bastion or SSH
ssh -i k8s-azure-key azureuser@<master-node-private-ip>

# Verify cluster status
kubectl get nodes
kubectl get pods -A

# Check cloud controllers
kubectl get pods -n kube-system -l component=cloud-controller-manager
kubectl get pods -n kube-system -l k8s-app=cloud-node-manager
```

## What Gets Deployed

### Azure Resources

- **Resource Group**: Container for all resources
- **Virtual Network**: 10.0.0.0/20 with Kubernetes and Bastion subnets
- **Network Security Group**: Controls traffic to Kubernetes subnet
- **Key Vault**: Stores kubeadm join command for workers
- **Managed Identity**: User-assigned identity for VMs with required permissions
- **Master Node VM**: Single control plane node
- **Worker VMSS**: Scalable worker node pool
- **Azure Bastion**: Secure access to VMs

### Kubernetes Components

- **Kubernetes v1.34.2**: Latest stable release
- **Calico CNI v3.28.0**: Network policy and pod networking
- **Azure Cloud Controller Manager**: Manages Azure load balancers
- **Azure Cloud Node Manager**: Manages node lifecycle and labels
- **CoreDNS**: Configured to forward to Azure DNS (168.63.129.16)
- **Azure Arc Agent**: Cluster management and monitoring

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

## Configuration Options

### VM Sizing

Adjust `vm_size` in `terraform.tfvars`:
- **Development**: Standard_D2ds_v5
- **Production**: Standard_D4ds_v5 or higher

### Worker Node Count

Set `worker_node_count` to scale worker nodes:
- **Single-node cluster**: 0 (master only)
- **Small cluster**: 2-3 workers
- **Production**: 5+ workers

### VM Type Selection

The infrastructure automatically determines `vmType` for Azure cloud config:
- `vmType: "standard"` when `worker_node_count = 0`
- `vmType: "vmss"` when `worker_node_count > 0`

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
