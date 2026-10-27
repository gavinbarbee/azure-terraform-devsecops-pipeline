output "storage_account_name" {
  description = "Workload storage account name."
  value       = azurerm_storage_account.workload.name
}

output "openai_account_name" {
  description = "Azure OpenAI account name. Needed to purge the soft-deleted account during cleanup."
  value       = azurerm_cognitive_account.openai.name
}

output "openai_endpoint" {
  description = "Azure OpenAI endpoint. Stored as the AZURE_OPENAI_ENDPOINT repository variable."
  value       = azurerm_cognitive_account.openai.endpoint
}

output "openai_deployment_name" {
  description = "Model deployment name. Stored as the AZURE_OPENAI_DEPLOYMENT repository variable."
  value       = azurerm_cognitive_deployment.chat.name
}
