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

# variable "log_analytics_workspace_id" {
#   type        = string
#   description = "Log Analytics Workspace ID from SSU" 
# }

locals {
  resource_group_name = "rg-2"
  location            = "eastus2"
  prefix              = "spc-vsu"
}

data "azurerm_log_analytics_workspace" "that" {
  name                = "spc-ssu-law-1"
  resource_group_name = "spc-ssu-rg-1"
}

# INFRASTRUCTURE STARTS HERE

resource "azurerm_resource_group" "this" {
  name     = format("%s-%s", local.prefix, local.resource_group_name)
  location = local.location
}

resource "azurerm_log_analytics_workspace" "this" {
  name                = format("%s-%s", local.prefix, "law-2")
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  sku                 = "PerGB2018"
  retention_in_days   = 30
}

resource "azurerm_storage_account" "this" {
  name                      = replace(format("%s-%s", local.prefix, "stg1"), "-", "")
  resource_group_name       = azurerm_resource_group.this.name
  location                  = azurerm_resource_group.this.location
  account_tier              = "Standard"
  account_replication_type  = "LRS"
  account_kind              = "StorageV2"
  enable_https_traffic_only = true
}


resource "azurerm_monitor_diagnostic_setting" "storage" {
  name                       = format("%s-%s", local.prefix, "transaction")
  target_resource_id         = azurerm_storage_account.this.id
  log_analytics_workspace_id = data.azurerm_log_analytics_workspace.that.id

  #   log {
  #     category = "AuditEvent"
  #     enabled  = true

  #     retention_policy {
  #       enabled = false
  #       days = 30
  #     }
  #   }

  metric {
    category = "Transaction"
    enabled  = true

    retention_policy {
      enabled = true
      days    = 30
    }
  }
}

resource "azurerm_container_registry" "this" {
  name                = replace(format("%s-%s", local.prefix, "acr-1"), "-", "")
  resource_group_name = azurerm_resource_group.this.name
  location            = azurerm_resource_group.this.location
  sku                 = "Premium"
  admin_enabled       = false

}

resource "azurerm_monitor_diagnostic_setting" "acr-monitor" {
  name                       = "DiagnosticsSettings"
  target_resource_id         = azurerm_container_registry.this.id
  log_analytics_workspace_id = azurerm_log_analytics_workspace.this.id

  log {
    category = "ContainerRegistryRepositoryEvents"
    enabled  = true

    retention_policy {
      enabled = true
      days    = 30
    }
  }

  log {
    category = "ContainerRegistryLoginEvents"
    enabled  = true

    retention_policy {
      enabled = true
      days    = 30
    }
  }

  metric {
    category = "AllMetrics"

    retention_policy {
      enabled = true
      days    = 30
    }
  }
}