# The workload resource group is created by bootstrap/bootstrap.ps1, not by
# Terraform. That lets the pipeline identity hold Contributor on this one group
# instead of the whole subscription.
data "azurerm_resource_group" "workload" {
  name = var.resource_group_name
}

# Random suffix keeps globally unique names unique across rebuilds.
resource "random_id" "suffix" {
  byte_length = 4
}

locals {
  suffix = random_id.suffix.hex
  tags   = merge(var.tags, { Environment = var.environment })
}

# ── Sample workload: storage account ─────────────────────────────────────────
# Hardened to pass the Checkov gate. Remaining exceptions are documented in
# .checkov.yaml with the reason for each.
resource "azurerm_storage_account" "workload" {
  name                     = "stgavinbarbee${local.suffix}"
  resource_group_name      = data.azurerm_resource_group.workload.name
  location                 = data.azurerm_resource_group.workload.location
  account_tier             = "Standard"
  account_replication_type = "LRS"
  account_kind             = "StorageV2"

  min_tls_version                 = "TLS1_2"
  https_traffic_only_enabled      = true
  allow_nested_items_to_be_public = false
  local_user_enabled              = false

  # Explicit so Checkov can evaluate the SAS policy (CKV2_AZURE_41). Same as the provider default; see CKV2_AZURE_40 in .checkov.yaml.
  shared_access_key_enabled = true

  # GitHub-hosted runners reach the data plane over the internet.
  # Exception documented in .checkov.yaml (CKV_AZURE_59).
  public_network_access_enabled = true

  blob_properties {
    delete_retention_policy {
      days = 7
    }
    container_delete_retention_policy {
      days = 7
    }
  }

  sas_policy {
    expiration_period = "00.01:00:00"
  }

  tags = local.tags
}

resource "azurerm_storage_container" "reports" {
  name                  = "reports"
  storage_account_id    = azurerm_storage_account.workload.id
  container_access_type = "private"
}

# Blob read/write/delete logging to Log Analytics through a diagnostic setting,
# Microsoft's current approach. See CKV2_AZURE_21 in .checkov.yaml.
resource "azurerm_log_analytics_workspace" "logs" {
  name                = "log-devsecops-gavinbarbee-${local.suffix}"
  resource_group_name = data.azurerm_resource_group.workload.name
  location            = data.azurerm_resource_group.workload.location
  sku                 = "PerGB2018"
  retention_in_days   = 30
  tags                = local.tags
}

resource "azurerm_monitor_diagnostic_setting" "blob_logs" {
  name                       = "blob-to-log-analytics"
  target_resource_id         = "${azurerm_storage_account.workload.id}/blobServices/default"
  log_analytics_workspace_id = azurerm_log_analytics_workspace.logs.id

  enabled_log {
    category = "StorageRead"
  }
  enabled_log {
    category = "StorageWrite"
  }
  enabled_log {
    category = "StorageDelete"
  }
}

# ── Azure OpenAI ─────────────────────────────────────────────────────────────
# Keyless: local (API key) auth is disabled, so callers must present an Entra
# ID token. Token auth requires a custom subdomain.
resource "azurerm_cognitive_account" "openai" {
  name                  = "oai-devsecops-gavinbarbee-${local.suffix}"
  resource_group_name   = data.azurerm_resource_group.workload.name
  location              = data.azurerm_resource_group.workload.location
  kind                  = "OpenAI"
  sku_name              = "S0"
  custom_subdomain_name = "oai-devsecops-gavinbarbee-${local.suffix}"

  local_auth_enabled = false

  # GitHub-hosted runners call the model over the internet.
  # Exception documented in .checkov.yaml (CKV_AZURE_134).
  public_network_access_enabled = true

  # Data loss prevention: block all outbound access. An empty allow-list is stricter than CKV_AZURE_247 accepts; documented in .checkov.yaml.
  outbound_network_access_restricted = true

  identity {
    type = "SystemAssigned"
  }

  tags = local.tags
}

resource "azurerm_cognitive_deployment" "chat" {
  name                 = var.model_deployment_name
  cognitive_account_id = azurerm_cognitive_account.openai.id

  model {
    format  = "OpenAI"
    name    = var.model_name
    version = var.model_version
  }

  sku {
    name     = var.model_sku
    capacity = var.model_capacity
  }
}
