# Using Azure CLI for Deployment
This section shows how to deploy and manage a private AKS cluster using your local console (as long as you have access to Azure and admin rights in your device). Follow along in order or the system won't work.

Note that this is not the recommended way to deploy and maintain infrastructure. Ideally, you would use IaC (Infrastructure as Code) and avoid this manual process; however, this is a great way to understand every part of the solution at a high level. Once you familiarize yourself with this section, I recommend using Terraform to bring up infrastructure in the future.

## Prerequisites
- Access to Azure (account and network access)
- A console (bash or zsh in this case) where you have admin rights
- An Azure subscription

## Setting up the environment
Once you have an [Azure account](https://azure.microsoft.com/en-us/free/search/), an Azure subscription, and can sign into the [Azure Portal](https://portal.azure.com/), open a console session.

You can install running the command below in Linux or MacOS, or you can look for [alternatives here](https://docs.microsoft.com/en-us/cli/azure/install-azure-cli).
```sh
curl -sL https://aka.ms/InstallAzureCLIDeb | sudo bash
```

Then, log into your Azure account by running
```sh
az login
```

Once you are in your account, select the subscription with which you want to work.
```sh
## Show available subscriptions
az account show -o table
## Set the subscription you want to use
# az account set -n YOUR_SUBSCRIPTION_NAME
```

Now you are ready to start deploying infrastructure.

## Set up environment variables
The following environment variables parametrize the deployment and are required to run the commands after this section. All you need to do to customize this process is to replace the values below with your preferred values. Everything should work fine if you leave the default values, though.

```sh
export REGION=eastus
export RESOURCE_GROUP=rg-private-aks-cli
export CLUSTER_NAME=aks-private-cluster
export VNET_NAME=vnet-private-aks
export VNET_CIDR=172.16.0.0/16
export SUBNET_NAME=subnet-private-aks
export SUBNET_CIDR=172.16.0.0/20
export CLUSTER_IDENTITY=identity-private-aks-cluster
export JUMPBOX_NAME=vm-jumpbox
export JUMPBOX_ADMIN_NAME=azureuser
export BASTION_PUBLIC_IP_NAME=bastion-ip-aks
export BASTION_HOST_NAME=bastion-private-aks
```

## Create the network and cluster
We will be using advanced networking (Azure CNI) so that k8s (kubernetes) pods are first-class citizens in the network and have their own IP address. This sample does not demonstrate the alternative "basic k8s networking" option in AKS.

Create a new resource group that will hold all of this guide's infrastructure (making it easy to clean up later by simply deleting this resource group).

```sh
az group create -l $REGION -n $RESOURCE_GROUP
```

### Network
Create a VNET (virtual network) and a subnet for our cluster, storing the subnet ID in an environment variable to use later.
```sh
# Create VNET
az network vnet create \
                --resource-group $RESOURCE_GROUP \
                --name $VNET_NAME \
                --address-prefixes $VNET_CIDR \
                --subnet-name $SUBNET_NAME \
                --subnet-prefix $SUBNET_CIDR

# Save subnet ID
export SUBNET_ID=$(az network vnet subnet list \
    --resource-group $RESOURCE_GROUP \
    --vnet-name $VNET_NAME \
    --query "[0].id" --output tsv)
```

### Cluster
Create a managed identity for the cluster's control plane to avoid using system default ones. Then, store its ID.
```sh
# Create a managed identity for the cluster's control plane
az identity create --name $CLUSTER_IDENTITY --resource-group $RESOURCE_GROUP

# Get new identity ID
export CLUSTER_IDENTITY_ID=$(az identity show --name $CLUSTER_IDENTITY \
                                --resource-group $RESOURCE_GROUP \
                                --query "@.id" -o tsv)
```

We can now create a private AKS cluster.
```sh
az aks create --name $CLUSTER_NAME \
                --resource-group $RESOURCE_GROUP \
                --load-balancer-sku standard \
                --assign-identity $CLUSTER_IDENTITY_ID\
                --enable-private-cluster \
                --network-plugin azure \
                --vnet-subnet-id $SUBNET_ID \
                --docker-bridge-address 172.17.0.1/16 \
                --dns-service-ip 10.2.0.10 \
                --service-cidr 10.2.0.0/24
```

## Connecting to the control plane (using the cluster)
Our cluster has been created; however, because it's a private cluster, the control plane is not accessible through the internet (i.e., our admin device). This is by design and desirable for security, so we'll have to access it indirectly through Azure-provided tooling.

I recommend two options to connect to the cluster:
1. Azure CLI and `command invoke` ([details here](https://docs.microsoft.com/en-us/azure/aks/command-invoke))
2. Using a jump box and [Azure Bastion](https://docs.microsoft.com/en-us/azure/bastion/bastion-overview).

### Azure AKS command invoke
We can run `kubectl` commands in a private AKS cluster by using [command invoke](https://docs.microsoft.com/en-us/azure/aks/command-invoke). We will need to pass inputs such as file names in both the `kubectl` command and in the az wrapper command, but it makes things simple when we only need to take a quick action in the cluster. Here's an example:
```sh
# Basic command
az aks command invoke \
                --resource-group $RESOURCE_GROUP \
                --name $CLUSTER_NAME \
                --command "kubectl get pods -n kube-system"

# Command with input file
az aks command invoke \
                --resource-group $RESOURCE_GROUP \
                --name $CLUSTER_NAME \
                --command "kubectl apply -f deployment.yaml -n default" \
                --file deployment.yaml
```

### Connecting using a jump box and Azure Bastion
While Azure AKS Command Invoke gets the job done for most commands, it can be slow and cumbersome for more involved administration of the cluster. Using a bastion is far better for most admnistrators, and we can deploy a basic VM in the cluster's network for that.

Please note that we will be using the same network and subnet for everything in this guide, but it's recommended to segment these components into their own subnets in production environmnets (e.g., one subnet for the jump box, one for the cluster, and one for the bastion).

First, we'll create a jump box VM in our network. You can replace the image used with a different Operating System or version of Ubuntu. Note that SSH keys will be generated with this command and must be stored for later use (AAD login for VMs is not in the scope of these instructions).

```sh
az vm create --image UbuntuLTS \
                --generate-ssh-keys \
                --admin-username $JUMPBOX_ADMIN_NAME \
                --location $REGION \
                --name $JUMPBOX_NAME \
                --resource-group $RESOURCE_GROUP \
                --size Standard_D2s_v3 \
                --vnet-name $VNET_NAME \
                --subnet $SUBNET_NAME \
                --output table

# Save the VM ID for use later
export JUMPBOX_ID=$(az vm show \
                --resource-group $RESOURCE_GROUP \
                --name $JUMPBOX_NAME \
                --query "@.id" --output tsv)
```

Then, we'll create a public IP address and assign it to an Azure Bastion as we create it.

```sh
# Create a public IP for the bastion
az network public-ip create \
                --name $BASTION_PUBLIC_IP_NAME \
                --resource-group $RESOURCE_GROUP \
                --location $REGION \
                --sku Standard

# Create a Bastion (this takes a long time)
az network bastion create \
                --location $REGION \
                --name $BASTION_HOST_NAME \
                --public-ip-address $BASTION_PUBLIC_IP_NAME \
                --resource-group $RESOURCE_GROUP \
                --vnet-name $VNET_NAME \
                --enable-tunneling true \
                --enable-ip-connect true
```

After the commands above finish, we can connect to our jump box with the following command (we have to use the SSH key generated when creating the jump box VM):

```sh
# You may have to change the location of your SSH keys depending on your environment.
az network bastion ssh \
                --name $BASTION_HOST_NAME \
                --resource-group $RESOURCE_GROUP \
                --target-resource-id $JUMPBOX_ID \
                --auth-type ssh-key \
                --username $JUMPBOX_ADMIN_NAME \
                --ssh-key ~/.ssh/id_rsa 
```

At this point, we have logged into our jump box via SSH and can execute commands. This machine will not have Azure CLI or kubectl installed, so we need to set it up. We just need to run the following commands in the VM one by one (follow instructions as needed):

```sh
## Install azure cli
curl -sL https://aka.ms/InstallAzureCLIDeb | sudo bash
## log into Azure
az login
## Install kubectl
sudo az aks install-cli
```

Finally, we need to get the k8s cluster credentials. Because our environment was set up locally, we need to run the following command in our local machine first and then copy that command for use in the VM session (this is in order to replace the environment variables into the command).

```sh
# Get cluster credentials for kubectl
echo "az aks get-credentials --resource-group $RESOURCE_GROUP --name $CLUSTER_NAME"

## Sample output to run in your jump box:
# az aks get-credentials --resource-group rg-private-aks-cli --name aks-private-cluster
```

We're all set now and can use kubectl on our private AKS cluster. To test it, run the following command to get your cluster's kube-system pods:
```sh
kubectl get pods -n kube-system
```

Happy kuberneting!