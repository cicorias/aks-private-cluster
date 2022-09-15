#!/bin/bash

# EDIT EVERY VARIABLE HERE

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

# REMEMBER TO SET YOUR SUBSCRIPTION FIRST!
## Check
# az account show -o table
## Set
# az account set -n YOUR_SUBSCRIPTION_NAME

az group create -l $REGION -n $RESOURCE_GROUP

# # Using basic kubernetes networking (i.e., pods don't have VPC IP Addresses)
# az aks create -n $CLUSTER_NAME \
#                 -g $RESOURCE_GROUP \
#                 --load-balancer-sku standard \
#                 --enable-private-cluster

# Create VNET
az network vnet create \
                --resource-group $RESOURCE_GROUP \
                --name $VNET_NAME \
                --address-prefixes $VNET_CIDR \
                --subnet-name $SUBNET_NAME \
                --subnet-prefix $SUBNET_CIDR

# SAMPLE GET SUBNET ID
# az network vnet subnet list \
#     --resource-group $RESOURCE_GROUP \
#     --vnet-name $VNET_NAME \
#     --query "[0].id" --output tsv

# Sample name = /subscriptions/<guid>/resourceGroups/myVnet/providers/Microsoft.Network/virtualNetworks/myVnet/subnets/default

# Get subnet ID
export SUBNET_ID=$(az network vnet subnet list \
    --resource-group $RESOURCE_GROUP \
    --vnet-name $VNET_NAME \
    --query "[0].id" --output tsv)

# Create a managed identity for the cluster's control plane
az identity create --name $CLUSTER_IDENTITY --resource-group $RESOURCE_GROUP

# Get new identity ID
export CLUSTER_IDENTITY_ID=$(az identity show --name $CLUSTER_IDENTITY \
                                --resource-group $RESOURCE_GROUP \
                                --query "@.id" -o tsv)

# Using Advanced networking (a.k.a. Azure CNI; i.e., pods have VPC IP addresses just like nodes)
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

# Install kubectl
sudo az aks install-cli

# Get cluster credentials for kubectl
az aks get-credentials --resource-group $RESOURCE_GROUP --name $CLUSTER_NAME

# Connecting to cluster
## Using command invoke to send kubectl commands:
az aks command invoke \
                --resource-group $RESOURCE_GROUP \
                --name $CLUSTER_NAME \
                --command "kubectl get pods -n kube-system"

## Using a Cloud Shell deployed to the cluster's network
## This one is too cumbersome to do in the CLI at this time. Use
## the portal by following the instructions here: https://docs.microsoft.com/en-us/azure/cloud-shell/private-vnet

## Using a jump box VM and Azure Bastion

# Create VM and find its key location (generally ~/.ssh/id_rsa)
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

export JUMPBOX_ID=$(az vm show \
                --resource-group $RESOURCE_GROUP \
                --name $JUMPBOX_NAME \
                --query "@.id" --output tsv)

az network public-ip create \
                --name $BASTION_PUBLIC_IP_NAME \
                --resource-group $RESOURCE_GROUP \
                --location $REGION \
                --sku Standard

# This takes A LONG TIME.
az network bastion create \
                --location $REGION \
                --name $BASTION_HOST_NAME \
                --public-ip-address $BASTION_PUBLIC_IP_NAME \
                --resource-group $RESOURCE_GROUP \
                --vnet-name $VNET_NAME \
                --enable-tunneling true \
                --enable-ip-connect true

az network bastion ssh \
                --name $BASTION_HOST_NAME \
                --resource-group $RESOURCE_GROUP \
                --target-resource-id $JUMPBOX_ID \
                --auth-type ssh-key \
                --username $JUMPBOX_ADMIN_NAME \
                --ssh-key ~/.ssh/id_rsa # you might have to change this!

# Once you're logged into the VM:
## Install azure cli
curl -sL https://aka.ms/InstallAzureCLIDeb | sudo bash
## log into Azure
az login
## Install kubectl
sudo az aks install-cli
## Get cluster credentials for kubectl
## (run this in your local machine to get the env variable names \
## and then run the output in the jumpbox)
echo "az aks get-credentials --resource-group $RESOURCE_GROUP --name $CLUSTER_NAME"

# Happy kuberneting!