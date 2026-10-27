<#
.SYNOPSIS
  One-time bootstrap for azure-terraform-devsecops-pipeline.

.DESCRIPTION
  Creates everything Terraform and the pipeline need before the first run:
    - Remote state: resource group, storage account (Entra-only auth), tfstate container
    - Workload resource group that the pipeline identity is scoped to
    - Entra app registration and service principal for GitHub Actions
    - Federated credentials for pull requests, the main branch, and the dev environment
    - Least-privilege role assignments for the pipeline identity and the signed-in user
    - GitHub repository secrets and the dev environment with a required reviewer

  Safe to re-run: each step checks for existing resources first.
  Run from the repo root after `az login` and `gh auth login`. The GitHub repo must exist.
#>

# Native commands (az, gh) don't throw on failure; every call is followed by Assert-Success.
$ErrorActionPreference = 'Continue'

# ── Settings ────────────────────────────────────────────────────────────────
$Location       = 'eastus2'
$StateRg        = 'rg-tfstate-gavinbarbee'
$StateSa        = 'stgavinbarbeetfstate'
$StateContainer = 'tfstate'
$WorkloadRg     = 'rg-devsecops-gavinbarbee-dev'
$AppName        = 'github-actions-devsecops-pipeline'
$Repo           = 'gavinbarbee/azure-terraform-devsecops-pipeline'
$Tags           = @('Project=azure-terraform-devsecops-pipeline', 'ManagedBy=Bootstrap', 'Owner=gavinbarbee')

function Assert-Success([string]$Step) {
    if ($LASTEXITCODE -ne 0) { throw "Bootstrap failed at: $Step" }
}

function Write-Step([string]$Message) {
    Write-Host "`n==> $Message" -ForegroundColor Cyan
}

function Grant-Role([string]$PrincipalId, [string]$PrincipalType, [string]$Role, [string]$Scope) {
    $existing = az role assignment list --assignee $PrincipalId --role $Role --scope $Scope --query "[0].id" -o tsv 2>$null
    if ($LASTEXITCODE -eq 0 -and $existing) {
        Write-Host "  $Role already assigned"
        return
    }
    az role assignment create --assignee-object-id $PrincipalId --assignee-principal-type $PrincipalType `
        --role $Role --scope $Scope -o none
    Assert-Success "assign $Role"
    Write-Host "  assigned $Role"
}

# ── Azure context ───────────────────────────────────────────────────────────
Write-Step 'Reading Azure context'
$SubscriptionId = az account show --query id -o tsv
Assert-Success 'az account show'
$TenantId = az account show --query tenantId -o tsv
Assert-Success 'az account show (tenant)'
$MyObjectId = az ad signed-in-user show --query id -o tsv
Assert-Success 'az ad signed-in-user show'
Write-Host "  Subscription: $(az account show --query name -o tsv)"

Write-Step 'Registering resource providers'
foreach ($ns in 'Microsoft.Storage', 'Microsoft.CognitiveServices') {
    az provider register --namespace $ns --wait -o none
    Assert-Success "register $ns"
    Write-Host "  $ns registered"
}

# ── Resource groups ─────────────────────────────────────────────────────────
Write-Step 'Creating resource groups'
az group create --name $StateRg --location $Location --tags $Tags -o none
Assert-Success 'create state resource group'
az group create --name $WorkloadRg --location $Location --tags $Tags -o none
Assert-Success 'create workload resource group'
$WorkloadRgId = az group show --name $WorkloadRg --query id -o tsv
Assert-Success 'show workload resource group'

# ── Remote state storage ────────────────────────────────────────────────────
Write-Step 'Creating state storage account'
az storage account show --name $StateSa --resource-group $StateRg -o none 2>$null
if ($LASTEXITCODE -ne 0) {
    $available = az storage account check-name --name $StateSa --query nameAvailable -o tsv
    Assert-Success 'check storage account name'
    if ($available -ne 'true') {
        throw "Storage account name '$StateSa' is taken. Change `$StateSa in this script and storage_account_name in terraform/backend.tf."
    }
    az storage account create --name $StateSa --resource-group $StateRg --location $Location `
        --sku Standard_LRS --kind StorageV2 --min-tls-version TLS1_2 `
        --allow-blob-public-access false --allow-shared-key-access false `
        --tags $Tags -o none
    Assert-Success 'create state storage account'
    Write-Host "  created $StateSa"
} else {
    Write-Host "  $StateSa already exists"
}
$StateSaId = az storage account show --name $StateSa --resource-group $StateRg --query id -o tsv
Assert-Success 'show state storage account'

Write-Step 'Granting you data access to the state account'
Grant-Role $MyObjectId 'User' 'Storage Blob Data Contributor' $StateSaId

Write-Step 'Creating tfstate container (retries while the role assignment propagates)'
$created = $false
for ($i = 1; $i -le 10 -and -not $created; $i++) {
    az storage container create --name $StateContainer --account-name $StateSa --auth-mode login -o none 2>$null
    if ($LASTEXITCODE -eq 0) {
        $created = $true
    } else {
        Write-Host "  waiting for RBAC to propagate ($i/10)..."
        Start-Sleep -Seconds 30
    }
}
if (-not $created) { throw 'Could not create the tfstate container after 5 minutes.' }
Write-Host "  container $StateContainer ready"

# ── Pipeline identity (OIDC, no client secret) ──────────────────────────────
Write-Step 'Creating app registration for GitHub Actions'
$AppId = az ad app list --display-name $AppName --query "[0].appId" -o tsv
Assert-Success 'list app registrations'
if (-not $AppId) {
    $AppId = az ad app create --display-name $AppName --query appId -o tsv
    Assert-Success 'create app registration'
    Write-Host "  created $AppName"
} else {
    Write-Host "  $AppName already exists"
}

$SpObjectId = az ad sp list --filter "appId eq '$AppId'" --query "[0].id" -o tsv
Assert-Success 'list service principals'
if (-not $SpObjectId) {
    $SpObjectId = az ad sp create --id $AppId --query id -o tsv
    Assert-Success 'create service principal'
    Write-Host '  created service principal'
}

Write-Step 'Adding federated credentials'
$Subjects = [ordered]@{
    'github-pull-requests' = "repo:${Repo}:pull_request"
    'github-main-branch'   = "repo:${Repo}:ref:refs/heads/main"
    'github-env-dev'       = "repo:${Repo}:environment:dev"
}
$ExistingCreds = @(az ad app federated-credential list --id $AppId --query "[].name" -o tsv)
Assert-Success 'list federated credentials'
foreach ($name in $Subjects.Keys) {
    if ($ExistingCreds -contains $name) {
        Write-Host "  $name already exists"
        continue
    }
    $credFile = Join-Path $env:TEMP "$name.json"
    $credJson = @{
        name      = $name
        issuer    = 'https://token.actions.githubusercontent.com'
        subject   = $Subjects[$name]
        audiences = @('api://AzureADTokenExchange')
    } | ConvertTo-Json
    [System.IO.File]::WriteAllText($credFile, $credJson)   # UTF-8 without BOM
    az ad app federated-credential create --id $AppId --parameters "@$credFile" -o none
    Assert-Success "create federated credential $name"
    Remove-Item $credFile
    Write-Host "  added $name -> $($Subjects[$name])"
}

# ── Least-privilege roles ───────────────────────────────────────────────────
Write-Step 'Assigning roles to the pipeline identity'
Grant-Role $SpObjectId 'ServicePrincipal' 'Contributor' $WorkloadRgId
Grant-Role $SpObjectId 'ServicePrincipal' 'Storage Blob Data Contributor' $StateSaId
Grant-Role $SpObjectId 'ServicePrincipal' 'Cognitive Services OpenAI User' $WorkloadRgId

Write-Step 'Assigning model access to you (for the local API wrapper)'
Grant-Role $MyObjectId 'User' 'Cognitive Services OpenAI User' $WorkloadRgId

# ── GitHub configuration ────────────────────────────────────────────────────
Write-Step 'Setting GitHub repository secrets (identifiers only, no credentials)'
gh secret set AZURE_CLIENT_ID --repo $Repo --body $AppId
Assert-Success 'set AZURE_CLIENT_ID'
gh secret set AZURE_TENANT_ID --repo $Repo --body $TenantId
Assert-Success 'set AZURE_TENANT_ID'
gh secret set AZURE_SUBSCRIPTION_ID --repo $Repo --body $SubscriptionId
Assert-Success 'set AZURE_SUBSCRIPTION_ID'

Write-Step 'Creating the dev environment with you as required reviewer'
$GhUserId = gh api user --jq .id
Assert-Success 'gh api user'
$envFile = Join-Path $env:TEMP 'gh-env-dev.json'
$envJson = @{
    reviewers           = @(@{ type = 'User'; id = [int64]$GhUserId })
    prevent_self_review = $false
} | ConvertTo-Json -Depth 5
[System.IO.File]::WriteAllText($envFile, $envJson)
gh api --method PUT "repos/$Repo/environments/dev" --input $envFile | Out-Null
Assert-Success 'create dev environment'
Remove-Item $envFile

Write-Step 'Bootstrap complete'
Write-Host 'Next: terraform init in the terraform folder.'
