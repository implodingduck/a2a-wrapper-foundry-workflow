terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "=4.45.1"
    }
    random = {
      source  = "hashicorp/random"
      version = "=3.1.0"
    }
    azapi = {
      source = "azure/azapi"
      version = "=2.3.0"
    }
    time = {
      source  = "hashicorp/time"
      version = "~> 0.13"
    }
    azuread = {
      source  = "hashicorp/azuread"
      version = "~> 2.53.1"
    }
  }
}

provider "azurerm" {
  features {
    resource_group {
      prevent_deletion_if_contains_resources = false
    }
  }

  subscription_id = var.subscription_id
}

resource "random_string" "unique" {
  length  = 8
  special = false
  upper   = false
}

data "azurerm_client_config" "current" {}

data "azurerm_log_analytics_workspace" "default" {
  name                = "DefaultWorkspace-${data.azurerm_client_config.current.subscription_id}-${local.loc_short}"
  resource_group_name = "DefaultResourceGroup-${local.loc_short}"
} 

resource "azurerm_resource_group" "rg" {
  name     = "rg-${local.gh_repo}-${random_string.unique.result}-${local.loc_for_naming}"
  location = var.location
  tags = local.tags
}

resource "azurerm_virtual_network" "default" {
  name                = "vnet-${local.func_name}-${local.loc_for_naming}"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  address_space       = ["172.19.0.0/16"]

  tags = local.tags
}

resource "azurerm_subnet" "default" {
  name                 = "default-subnet-${local.loc_for_naming}"
  resource_group_name  = azurerm_resource_group.rg.name
  virtual_network_name = azurerm_virtual_network.default.name
  address_prefixes     = ["172.19.0.0/24"]
}

resource "azurerm_subnet" "cluster" {
  name                 = "cluster-subnet-${local.loc_for_naming}"
  resource_group_name  = azurerm_resource_group.rg.name
  virtual_network_name = azurerm_virtual_network.default.name
  address_prefixes     = ["172.19.1.0/24"]

  delegation {
    name = "Microsoft.App/environments"
    service_delegation {
      name    = "Microsoft.App/environments"
      actions = ["Microsoft.Network/virtualNetworks/subnets/join/action"]
    }
  
  }
}


resource "azurerm_subnet" "pe" {
  name                 = "pe-subnet-${local.loc_for_naming}"
  resource_group_name  = azurerm_resource_group.rg.name
  virtual_network_name = azurerm_virtual_network.default.name
  address_prefixes     = ["172.19.2.0/24"]
}

resource "azurerm_key_vault" "kv" {
  name                       = "kv-${local.func_name}"
  location                   = azurerm_resource_group.rg.location
  resource_group_name        = azurerm_resource_group.rg.name
  tenant_id                  = data.azurerm_client_config.current.tenant_id
  sku_name                   = "standard"
  soft_delete_retention_days = 7
  purge_protection_enabled   = false
  rbac_authorization_enabled = true

}

resource "random_password" "password" {
  length           = 16
  special          = false
}

resource "azurerm_key_vault_secret" "apikey" {
  depends_on = [ azurerm_role_assignment.kv_officer, azurerm_role_assignment.kv_cert_officer ]
  name         = "A2A-API-KEY"
  value        = random_password.password.result
  key_vault_id = azurerm_key_vault.kv.id
}

resource "azurerm_role_assignment" "kv_officer" {
  scope                            = azurerm_key_vault.kv.id
  role_definition_name             = "Key Vault Secrets Officer"
  principal_id                     = data.azurerm_client_config.current.object_id
}

resource "azurerm_role_assignment" "kv_cert_officer" {
  scope                            = azurerm_key_vault.kv.id
  role_definition_name             = "Key Vault Certificates Officer"
  principal_id                     = data.azurerm_client_config.current.object_id
}

resource "azurerm_application_insights" "app" {
  name                = "${local.func_name}-insights"
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location
  application_type    = "other"
  workspace_id        = data.azurerm_log_analytics_workspace.default.id
}

resource "azurerm_user_assigned_identity" "this" {
  location            = azurerm_resource_group.rg.location
  name                = "uai-${local.func_name}"
  resource_group_name = azurerm_resource_group.rg.name
}

resource "azurerm_role_assignment" "containerapptokv" {
  scope                = azurerm_key_vault.kv.id
  role_definition_name = "Key Vault Secrets User"
  principal_id         = azurerm_user_assigned_identity.this.principal_id
}

resource "azurerm_role_assignment" "containerapptofoundry" {
  scope                = var.FOUNDRY_RESOURCE_ID
  role_definition_name = "Azure AI User"
  principal_id         = azurerm_user_assigned_identity.this.principal_id
}

resource "azurerm_role_assignment" "reader" {
  scope                = "/subscriptions/${data.azurerm_client_config.current.subscription_id}"
  role_definition_name = "Reader"
  principal_id         = azurerm_user_assigned_identity.this.principal_id
}

resource "azurerm_container_app_environment" "this" {
  name                       = "ace-${local.func_name}"
  location                   = azurerm_resource_group.rg.location
  resource_group_name        = azurerm_resource_group.rg.name
  log_analytics_workspace_id = data.azurerm_log_analytics_workspace.default.id

  infrastructure_subnet_id = azurerm_subnet.cluster.id

  workload_profile {
    name                  = "Consumption"
    workload_profile_type = "Consumption"
  }

  tags = local.tags
  lifecycle {
    ignore_changes = [
     infrastructure_resource_group_name,
     log_analytics_workspace_id
    ]
  }
}

resource "azurerm_container_app" "a2a" {
  name                         = "aca-${local.func_name}"
  container_app_environment_id = azurerm_container_app_environment.this.id
  resource_group_name          = azurerm_resource_group.rg.name
  revision_mode                = "Single"
  workload_profile_name        = "Consumption"

  template {
    container {
      name   = "a2a"
      image  = "ghcr.io/${var.gh_repo}:latest"
      cpu    = 0.25
      memory = "0.5Gi"

      env {
        name  = "AZURE_SUBSCRIPTION_ID"
        value = data.azurerm_client_config.current.subscription_id
      }
      env {
        name  = "AZURE_TENANT_ID"
        value = data.azurerm_client_config.current.tenant_id

      }
      env {
        name  = "AZURE_CLIENT_ID"
        value = azurerm_user_assigned_identity.this.client_id
      }
      env {
        name  = "FOUNDRY_WORKFLOW_ENDPOINT"
        value = var.FOUNDRY_WORKFLOW_ENDPOINT
      }
      env {
        name  = "FOUNDRY_WORKFLOW_NAME"
        value = var.FOUNDRY_WORKFLOW_NAME
      }
      env {
        name  = "FOUNDRY_WORKFLOW_VERSION"
        value = var.FOUNDRY_WORKFLOW_VERSION
      }
      env {
        name = "API_KEY"
        secret_name = "a2a-api-key"
      }
    }
    http_scale_rule {
      name                = "http-1"
      concurrent_requests = "100"
    }
    min_replicas = 1
    max_replicas = 1
  }

  ingress {
    allow_insecure_connections = false
    external_enabled           = true
    target_port                = 8000
    transport                  = "auto"
    traffic_weight {
      latest_revision = true
      percentage      = 100
    }
  }

  secret {
    name = "a2a-api-key"
    identity = azurerm_user_assigned_identity.this.id
    key_vault_secret_id = azurerm_key_vault_secret.apikey.id
  }

  identity {
    type = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.this.id]
  }
  tags = local.tags

  lifecycle {
    ignore_changes = [ secret ]
  }
}
