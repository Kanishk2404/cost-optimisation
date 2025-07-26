terraform {
  required_version = ">= 1.0  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~>3.80"
    }
    random = {
      source  = "hashicorp/random"
      version = "~>3.1"
    }
  }
}

provider "azurerm" {
  features {
    resource_group {
      prevent_deletion_if_contains_resources = false
    }
  }
}

variable "location" {
  description = "Azure region"
  type        = string
  default     = "East US"
}

variable "environment" {
  description = "Environment name"
  type        = string
  default     = "prod"
}

variable "cosmos_throughput" {
  description = "Cosmos DB throughput (RU/s)"
  type        = number
  default     = 600
}

resource "random_string" "suffix" {
  length  = 6
  special = false
  upper   = false
}

locals {
  resource_suffix = "${var.environment}-${random_string.suffix.result}"
  common_tags = {
    Environment = var.environment
    Project     = "billing-optimization"
    ManagedBy   = "terraform"
  }
}

resource "azurerm_resource_group" "main" {
  name     = "rg-billing-optimization-${local.resource_suffix}"
  location = var.location
  tags     = local.common_tags
}

resource "azurerm_cosmosdb_account" "main" {
  name                = "cosmos-billing-${local.resource_suffix}"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  offer_type          = "Standard"
  kind                = "GlobalDocumentDB"

  enable_automatic_failover       = true
  enable_multiple_write_locations = false

  consistency_policy {
    consistency_level       = "Session"
    max_interval_in_seconds = 5
    max_staleness_prefix    = 100
  }

  geo_location {
    location          = azurerm_resource_group.main.location
    failover_priority = 0
    zone_redundant    = false
  }

  backup {
    type                = "Periodic"
    interval_in_minutes = 240
    retention_in_hours  = 8
    storage_redundancy  = "Geo"
  }

  tags = local.common_tags
}

resource "azurerm_cosmosdb_sql_database" "billing" {
  name                = "billing"
  resource_group_name = azurerm_resource_group.main.name
  account_name        = azurerm_cosmosdb_account.main.name
  throughput          = var.cosmos_throughput
}

resource "azurerm_cosmosdb_sql_container" "records" {
  name                  = "records"
  resource_group_name   = azurerm_resource_group.main.name
  account_name          = azurerm_cosmosdb_account.main.name
  database_name         = azurerm_cosmosdb_sql_database.billing.name
  partition_key_path    = "/partitionKey"
  partition_key_version = 1

  indexing_policy {
    indexing_mode = "consistent"
    included_path {
      path = "/*"
    }
    excluded_path {
      path = "/\"_etag\"/?"
    }
  }

  unique_key {
    paths = ["/id"]
  }
}

resource "azurerm_storage_account" "main" {
  name                     = "stbilling${random_string.suffix.result}"
  resource_group_name      = azurerm_resource_group.main.name
  location                 = azurerm_resource_group.main.location
  account_tier             = "Standard"
  account_replication_type = "LRS"

  blob_properties {
    delete_retention_policy {
      days = 7
    }
    versioning_enabled = true
  }

  tags = local.common_tags
}

resource "azurerm_storage_container" "archived_billing" {
  name                  = "archived-billing"
  storage_account_name  = azurerm_storage_account.main.name
  container_access_type = "private"
}

resource "azurerm_storage_management_policy" "lifecycle" {
  storage_account_id = azurerm_storage_account.main.id

  rule {
    name    = "archiveBillingRecords"
    enabled = true

    filters {
      prefix_match = ["archived-billing/"]
      blob_types   = ["blockBlob"]
    }

    actions {
      base_blob {
        tier_to_cool_after_days_since_modification_greater_than    = 90
        tier_to_archive_after_days_since_modification_greater_than = 180
        delete_after_days_since_modification_greater_than          = 2555
      }
    }
  }
}

resource "azurerm_application_insights" "main" {
  name                = "appi-billing-${local.resource_suffix}"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  application_type    = "web"
  tags                = local.common_tags
}

resource "azurerm_service_plan" "main" {
  name                = "plan-billing-${local.resource_suffix}"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  os_type             = "Linux"
  sku_name            = "Y1"
  tags                = local.common_tags
}

resource "azurerm_linux_function_app" "main" {
  name                       = "func-billing-${local.resource_suffix}"
  resource_group_name        = azurerm_resource_group.main.name
  location                   = azurerm_resource_group.main.location
  storage_account_name       = azurerm_storage_account.main.name
  storage_account_access_key = azurerm_storage_account.main.primary_access_key
  service_plan_id            = azurerm_service_plan.main.id

  site_config {
    application_stack {
      node_version = "18"
    }
    application_insights_key = azurerm_application_insights.main.instrumentation_key
    cors {
      allowed_origins = ["*"]
    }
  }

  app_settings = {
    COSMOS_CONNECTION_STRING  = azurerm_cosmosdb_account.main.connection_strings[0]
    STORAGE_CONNECTION_STRING = azurerm_storage_account.main.primary_connection_string
    APPLICATION_INSIGHTS_KEY  = azurerm_application_insights.main.instrumentation_key
    FUNCTIONS_WORKER_RUNTIME  = "node"
    WEBSITE_NODE_DEFAULT_VERSION = "~18"
  }

  tags = local.common_tags
}

output "resource_group_name" {
  value = azurerm_resource_group.main.name
}

output "cosmos_db_endpoint" {
  value = azurerm_cosmosdb_account.main.endpoint
}

output "storage_account_name" {
  value = azurerm_storage_account.main.name
}

output "function_app_name" {
  value = azurerm_linux_function_app.main.name
}

output "function_app_url" {
  value = "https://${azurerm_linux_function_app.main.name}.azurewebsites.net"
}
