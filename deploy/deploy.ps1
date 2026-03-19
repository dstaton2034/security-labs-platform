<#
.SYNOPSIS
    Deploys the Security Labs Platform to Azure Blob Storage Static Website.

.DESCRIPTION
    This script creates an Azure Storage Account with Static Website hosting enabled,
    uploads all platform files, and optionally sets up Azure CDN for custom domain + HTTPS.

.PARAMETER ResourceGroupName
    Name of the Azure Resource Group (created if it doesn't exist).

.PARAMETER StorageAccountName
    Globally unique name for the Storage Account (3-24 chars, lowercase + numbers only).

.PARAMETER Location
    Azure region (default: eastus2).

.PARAMETER EnableCDN
    If set, creates an Azure CDN profile and endpoint for custom domain support.

.EXAMPLE
    .\deploy.ps1 -ResourceGroupName "rg-security-labs" -StorageAccountName "securitylabs2026" -Location "eastus2"

.EXAMPLE
    .\deploy.ps1 -ResourceGroupName "rg-security-labs" -StorageAccountName "securitylabs2026" -EnableCDN
#>

param(
    [Parameter(Mandatory = $true)]
    [string]$ResourceGroupName,

    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[a-z0-9]{3,24}$')]
    [string]$StorageAccountName,

    [string]$Location = "eastus2",

    [switch]$EnableCDN
)

$ErrorActionPreference = "Stop"
$platformDir = Split-Path -Parent $PSScriptRoot  # Parent of deploy/ folder

Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "  Security Labs Platform — Azure Deploy" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""

# ─── Prerequisites Check ─────────────────────────────────────────────
Write-Host "[1/6] Checking prerequisites..." -ForegroundColor Yellow

$azVersion = az --version 2>&1 | Select-Object -First 1
if (-not $azVersion) {
    Write-Host "ERROR: Azure CLI (az) is not installed. Install from https://aka.ms/installazurecli" -ForegroundColor Red
    exit 1
}
Write-Host "  ✓ Azure CLI found: $azVersion" -ForegroundColor Green

$account = az account show --query "{name:name, id:id}" -o tsv 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Host "  ⚠ Not logged in. Running 'az login'..." -ForegroundColor Yellow
    az login
}
$accountName = az account show --query "name" -o tsv
Write-Host "  ✓ Logged in to: $accountName" -ForegroundColor Green

# ─── Resource Group ──────────────────────────────────────────────────
Write-Host ""
Write-Host "[2/6] Ensuring Resource Group '$ResourceGroupName'..." -ForegroundColor Yellow

$rgExists = az group exists --name $ResourceGroupName -o tsv
if ($rgExists -eq "false") {
    az group create --name $ResourceGroupName --location $Location --output none
    Write-Host "  ✓ Created resource group '$ResourceGroupName' in $Location" -ForegroundColor Green
} else {
    Write-Host "  ✓ Resource group already exists" -ForegroundColor Green
}

# ─── Storage Account ────────────────────────────────────────────────
Write-Host ""
Write-Host "[3/6] Creating Storage Account '$StorageAccountName'..." -ForegroundColor Yellow

$saExists = az storage account check-name --name $StorageAccountName --query "nameAvailable" -o tsv
if ($saExists -eq "true") {
    az storage account create `
        --name $StorageAccountName `
        --resource-group $ResourceGroupName `
        --location $Location `
        --sku Standard_LRS `
        --kind StorageV2 `
        --min-tls-version TLS1_2 `
        --allow-blob-public-access true `
        --output none
    Write-Host "  ✓ Storage Account created" -ForegroundColor Green
} else {
    Write-Host "  ✓ Storage Account already exists (or name taken)" -ForegroundColor Green
}

# Get storage key
$storageKey = az storage account keys list `
    --account-name $StorageAccountName `
    --resource-group $ResourceGroupName `
    --query "[0].value" -o tsv

# ─── Enable Static Website ──────────────────────────────────────────
Write-Host ""
Write-Host "[4/6] Enabling Static Website hosting..." -ForegroundColor Yellow

az storage blob service-properties update `
    --account-name $StorageAccountName `
    --account-key $storageKey `
    --static-website `
    --index-document "index.html" `
    --404-document "index.html" `
    --output none

Write-Host "  ✓ Static Website enabled (index: index.html, 404: index.html)" -ForegroundColor Green

# ─── Upload Files ────────────────────────────────────────────────────
Write-Host ""
Write-Host "[5/6] Uploading platform files..." -ForegroundColor Yellow

# Content type mappings
$contentTypes = @{
    ".html" = "text/html"
    ".css"  = "text/css"
    ".js"   = "application/javascript"
    ".json" = "application/json"
    ".png"  = "image/png"
    ".jpg"  = "image/jpeg"
    ".svg"  = "image/svg+xml"
    ".ico"  = "image/x-icon"
    ".woff" = "font/woff"
    ".woff2"= "font/woff2"
}

# Upload with batch command
az storage blob upload-batch `
    --account-name $StorageAccountName `
    --account-key $storageKey `
    --destination '$web' `
    --source $platformDir `
    --pattern "*" `
    --overwrite `
    --output none

Write-Host "  ✓ All files uploaded to `$web container" -ForegroundColor Green

# ─── CDN (Optional) ─────────────────────────────────────────────────
if ($EnableCDN) {
    Write-Host ""
    Write-Host "[6/6] Setting up Azure CDN..." -ForegroundColor Yellow

    $cdnProfile = "$StorageAccountName-cdn"
    $cdnEndpoint = "$StorageAccountName-endpoint"
    $staticUrl = az storage account show --name $StorageAccountName --query "primaryEndpoints.web" -o tsv
    $originHost = ($staticUrl -replace "https://", "" -replace "/$", "")

    az cdn profile create `
        --name $cdnProfile `
        --resource-group $ResourceGroupName `
        --sku Standard_Microsoft `
        --output none

    az cdn endpoint create `
        --name $cdnEndpoint `
        --profile-name $cdnProfile `
        --resource-group $ResourceGroupName `
        --origin $originHost `
        --origin-host-header $originHost `
        --enable-compression `
        --output none

    $cdnUrl = "https://$cdnEndpoint.azureedge.net"
    Write-Host "  ✓ CDN Endpoint: $cdnUrl" -ForegroundColor Green
    Write-Host "  ℹ To add a custom domain, run:" -ForegroundColor Gray
    Write-Host "    az cdn custom-domain create --endpoint-name $cdnEndpoint --profile-name $cdnProfile -g $ResourceGroupName --hostname your.domain.com -n customdomain" -ForegroundColor Gray
}

# ─── Output ──────────────────────────────────────────────────────────
Write-Host ""
Write-Host "========================================" -ForegroundColor Green
Write-Host "  ✅ Deployment Complete!" -ForegroundColor Green
Write-Host "========================================" -ForegroundColor Green
Write-Host ""

$siteUrl = az storage account show --name $StorageAccountName --query "primaryEndpoints.web" -o tsv
Write-Host "  🌐 Your Security Labs Platform is live at:" -ForegroundColor Cyan
Write-Host "     $siteUrl" -ForegroundColor White
Write-Host ""
if ($EnableCDN) {
    Write-Host "  🚀 CDN URL:" -ForegroundColor Cyan
    Write-Host "     $cdnUrl" -ForegroundColor White
    Write-Host ""
}
Write-Host "  📝 To update content later:" -ForegroundColor Yellow
Write-Host "     az storage blob upload-batch --account-name $StorageAccountName --account-key <key> --destination '`$web' --source $platformDir --overwrite" -ForegroundColor Gray
Write-Host ""
Write-Host "  💡 To add a new lab:" -ForegroundColor Yellow
Write-Host "     1. Create labs/<name>/content.json (use AI Generator or manually)" -ForegroundColor Gray
Write-Host "     2. Add entry to manifest.json" -ForegroundColor Gray
Write-Host "     3. Re-run this deploy script" -ForegroundColor Gray
Write-Host ""
