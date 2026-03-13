<#
.SYNOPSIS
    Exports all installed marketplace extensions in the Azure DevOps organization.

.DESCRIPTION
    Lists all installed Azure DevOps marketplace extensions with their publisher,
    version, state, and scope information. Extensions may need re-authorization
    after the tenant migration.

    Output: CSV file with extension details.

.PARAMETER Organization
    The Azure DevOps organization name.

.PARAMETER OutputPath
    Directory where the export files will be saved. Defaults to ./output.

.PREREQUISITES
    - Azure CLI installed with Azure DevOps extension
    - Authenticated to Azure DevOps
    - Project Collection Administrator role

.EXAMPLE
    .\05-Export-Extensions.ps1 -Organization "myorg"

.NOTES
    Migration Phase : Pre-Migration
    Checklist Item  : #6 - Inventory all installed marketplace extensions
    Author          : Migration Team
    Date            : 2026-03-13
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$Organization,

    [Parameter(Mandatory = $false)]
    [string]$OutputPath = "./output"
)

$ErrorActionPreference = "Stop"
$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"

if (-not (Test-Path $OutputPath)) {
    New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null
}

$orgUrl = "https://dev.azure.com/$Organization"

Write-Host "============================================================" -ForegroundColor Cyan
Write-Host " Export Marketplace Extensions — $orgUrl" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host ""

# ── Retrieve all extensions ────────────────────────────────────────────────
Write-Host "[1/1] Retrieving installed extensions..." -ForegroundColor Yellow

$extensions = az devops extension list --org $orgUrl -o json | ConvertFrom-Json

$extensionExport = $extensions | ForEach-Object {
    [PSCustomObject]@{
        ExtensionName  = $_.extensionName
        ExtensionId    = $_.extensionId
        PublisherName  = $_.publisherName
        PublisherId    = $_.publisherId
        Version        = $_.version
        Flags          = ($_.flags -join ", ")
        InstallState   = $_.installState.flags
        LastUpdated    = $_.lastPublished
        Scopes         = ($_.scopes -join ", ")
    }
}

# ── Export results ──────────────────────────────────────────────────────────
$extensionsFile = Join-Path $OutputPath "extensions_${timestamp}.csv"
$extensionExport | Export-Csv -Path $extensionsFile -NoTypeInformation -Encoding UTF8

Write-Host ""
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host " Export Complete" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "  Total extensions   : $($extensionExport.Count)" -ForegroundColor Green
Write-Host "  Exported to        : $extensionsFile" -ForegroundColor Green
Write-Host ""
Write-Host ">> Review extensions that use identity-based permissions." -ForegroundColor Yellow
Write-Host ">> Some extensions may need re-authorization after the tenant switch." -ForegroundColor Yellow
