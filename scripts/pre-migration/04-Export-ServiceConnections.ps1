<#
.SYNOPSIS
    Exports all service connections across all Azure DevOps projects.

.DESCRIPTION
    Inventories all service connections (service endpoints) in every project
    of the organization, including their type, authorization details, and
    associated service principal information.

    This is critical because service connections using contoso.com service
    principals must be reconfigured with zava.com service principals after migration.

    Output: CSV file with service connection details per project.

.PARAMETER Organization
    The Azure DevOps organization name.

.PARAMETER OutputPath
    Directory where the export files will be saved. Defaults to ./output.

.PREREQUISITES
    - Azure CLI installed with Azure DevOps extension
    - Authenticated to Azure DevOps
    - Project Collection Administrator or Endpoint Administrator role

.EXAMPLE
    .\04-Export-ServiceConnections.ps1 -Organization "myorg"

.NOTES
    Migration Phase : Pre-Migration
    Checklist Item  : #5 - Inventory all service connections across all projects
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
Write-Host " Export Service Connections — $orgUrl" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host ""

# ── Retrieve all projects ──────────────────────────────────────────────────
Write-Host "[1/2] Retrieving projects..." -ForegroundColor Yellow

$projects = az devops project list --org $orgUrl -o json | ConvertFrom-Json
Write-Host "  Found $($projects.value.Count) projects." -ForegroundColor Green

# ── Retrieve service connections per project ────────────────────────────────
Write-Host "[2/2] Retrieving service connections..." -ForegroundColor Yellow

$allEndpoints = @()

foreach ($project in $projects.value) {
    Write-Host "  Project: $($project.name)..." -ForegroundColor Gray

    try {
        $endpoints = az devops service-endpoint list `
            --org $orgUrl `
            --project $project.name `
            -o json | ConvertFrom-Json

        foreach ($ep in $endpoints) {
            $allEndpoints += [PSCustomObject]@{
                ProjectName          = $project.name
                EndpointName         = $ep.name
                EndpointId           = $ep.id
                EndpointType         = $ep.type
                Url                  = $ep.url
                IsShared             = $ep.isShared
                IsReady              = $ep.isReady
                AuthorizationScheme  = $ep.authorization.scheme
                ServicePrincipalId   = $ep.authorization.parameters.serviceprincipalid
                TenantId             = $ep.authorization.parameters.tenantid
                CreatedByName        = $ep.createdBy.displayName
                CreatedByUPN         = $ep.createdBy.uniqueName
                Description          = $ep.description
            }
        }

        Write-Host "    Found $($endpoints.Count) service connections." -ForegroundColor Gray
    } catch {
        Write-Warning "    Could not retrieve endpoints for project: $($project.name)"
    }
}

# ── Export results ──────────────────────────────────────────────────────────
$endpointsFile = Join-Path $OutputPath "service-connections_${timestamp}.csv"
$allEndpoints | Export-Csv -Path $endpointsFile -NoTypeInformation -Encoding UTF8

# Identify connections tied to the source tenant
$sourceTenantConnections = $allEndpoints | Where-Object { $_.TenantId -and $_.EndpointType -eq "azurerm" }
$sourceTenantFile = Join-Path $OutputPath "service-connections-azure_${timestamp}.csv"
$sourceTenantConnections | Export-Csv -Path $sourceTenantFile -NoTypeInformation -Encoding UTF8

Write-Host ""
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host " Export Complete" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "  Total service connections : $($allEndpoints.Count)" -ForegroundColor Green
Write-Host "  Azure RM connections      : $($sourceTenantConnections.Count)" -ForegroundColor Green
Write-Host "  All connections file      : $endpointsFile" -ForegroundColor Green
Write-Host "  Azure connections file    : $sourceTenantFile" -ForegroundColor Green
Write-Host ""
Write-Host ">> Azure RM connections with source tenant IDs must be reconfigured after migration." -ForegroundColor Yellow
Write-Host ">> Record the service principal IDs — new ones must be created in the target tenant." -ForegroundColor Yellow
