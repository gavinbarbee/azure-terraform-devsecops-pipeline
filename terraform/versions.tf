terraform {
  required_version = ">= 1.9.0"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }
}

provider "azurerm" {
  features {}

  subscription_id = var.subscription_id

  # The pipeline identity only has rights on the workload resource group, so it
  # cannot register resource providers at subscription scope. bootstrap.ps1
  # registers the two providers this configuration needs.
  resource_provider_registrations = "none"
}
