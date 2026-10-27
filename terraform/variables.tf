variable "subscription_id" {
  description = "Azure subscription ID. Set in terraform.tfvars locally and through TF_VAR_subscription_id in the pipeline."
  type        = string
}

variable "resource_group_name" {
  description = "Existing workload resource group created by bootstrap/bootstrap.ps1. The pipeline identity is scoped to this group only."
  type        = string
  default     = "rg-devsecops-gavinbarbee-dev"
}

variable "environment" {
  description = "Environment label applied as a tag."
  type        = string
  default     = "dev"
}

variable "model_deployment_name" {
  description = "Name of the Azure OpenAI model deployment. The pipeline and the API wrapper call the model by this name."
  type        = string
  default     = "chat"
}

variable "model_name" {
  description = "Azure OpenAI model to deploy. Check regional availability with: az cognitiveservices model list --location eastus2"
  type        = string
  default     = "gpt-4.1-mini"
}

variable "model_version" {
  description = "Model version string. Must be available in the deployment region."
  type        = string
  default     = "2025-04-14"
}

variable "model_sku" {
  description = "Deployment type for the model."
  type        = string
  default     = "GlobalStandard"
}

variable "model_capacity" {
  description = "Model capacity in thousands of tokens per minute. Kept low to stay inside default quota."
  type        = number
  default     = 10
}

variable "tags" {
  description = "Tags applied to every resource."
  type        = map(string)
  default = {
    Project   = "azure-terraform-devsecops-pipeline"
    ManagedBy = "Terraform"
    Owner     = "gavinbarbee"
  }
}
