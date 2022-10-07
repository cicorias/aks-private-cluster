terraform {
  required_version = ">= 1.2.7"

  backend "local" {}

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "=3.24.0"
    }
  }
}

provider "azurerm" {
  features {
    # see https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/guides/features-block
    resource_group {
      prevent_deletion_if_contains_resources = true
    }

    # key_vault {
    #   purge_soft_delete_on_destroy    = true
    #   recover_soft_deleted_key_vaults = true
    # }

    # virtual_machine {
    #   delete_os_disk_on_deletion     = true
    # }
  }
}

locals {
  resource_group_name = "rg-1"
  location            = "eastus2"
  prefix              = "spc-ssu"
}

# INFRASTRUCTURE STARTS HERE

resource "azurerm_resource_group" "this" {
  name     = format("%s-%s", local.prefix, local.resource_group_name)
  location = local.location
}

resource "azurerm_log_analytics_workspace" "this" {
  name                = format("%s-%s", local.prefix, "law-1")
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  sku                 = "PerGB2018"
  retention_in_days   = 30
}

output "log_analytics_workspace_id" {
  value = azurerm_log_analytics_workspace.this.id
}