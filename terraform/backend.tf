terraform {
  backend "azurerm" {
    resource_group_name  = "rg-tfstate-gavinbarbee"
    storage_account_name = "stgavinbarbeetfstate"
    container_name       = "tfstate"
    key                  = "devsecops-pipeline.tfstate"

    # Entra ID auth to blob storage. The state account has shared key access
    # disabled, so there are no storage keys to leak.
    use_azuread_auth = true
  }
}
