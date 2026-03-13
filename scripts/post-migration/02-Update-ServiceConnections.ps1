<#
.SYNOPSIS
    Updates Azure DevOps service connections with new service principals from the target tenant.

.DESCRIPTION
    After the tenant migration, service connections using service principals from the
    source tenant must be reconfigured with new service principals from the target tenant.
    This script reads the service connection inventory and the new app credentials,
    then updates each service connection via the Azure DevOps REST API.

    Output: CSV file with update results.

.PARAMETER Organization
    The Azure DevOps organization name.

.PARAMETER ServiceConnectionsFile
    Path to the CSV exported by 04-Export-ServiceConnections.ps1 (service-connections-azure_*.csv).

.PARAMETER AppCredentialsFile
    Path to the CSV exported by 04-Create-AppRegistrations.ps1 (app-credentials_*.csv).

.PARAMETER TargetTenantId
    The Entra ID tenant ID of the target tenant (zava.com).

.PARAMETER WhatIf
    If specified, generates the plan without updating connections.

.PARAMETER OutputPath
    Directory where the export files will be saved. Defaults to ./output.

.PREREQUISITES
    - Azure CLI installed with Azure DevOps extension
    - Authenticated to Azure DevOps
    - Endpoint Administrator or Project Collection Administrator role

.EXAMPLE
    .\02-Update-ServiceConnections.ps1 -Organization "myorg" `
        -ServiceConnectionsFile "./output/service-connections-azure.csv" `
        -AppCredentialsFile "./output/app-credentials.csv" `
        -TargetTenantId "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"

.NOTES
    Migration Phase : Post-Migration
    Checklist Item  : #4 - Reconfigure all service connections with target tenant service principals
    Author          : Migration Team
    Date            : 2026-03-13
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory = $true)]
    [string]$Organization,

    [Parameter(Mandatory = $true)]
    [string]$ServiceConnectionsFile,

    [Parameter(Mandatory = $true)]
    [string]$AppCredentialsFile,

    [Parameter(Mandatory = $true)]
    [string]$TargetTenantId,

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
Write-Host " Update Service Connections — $orgUrl" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host ""

# ── Load data ─────────────────────────────────────────────────────────────
Write-Host "[1/2] Loading service connections and app credentials..." -ForegroundColor Yellow

$serviceConnections = Import-Csv -Path $ServiceConnectionsFile
$appCredentials = Import-Csv -Path $AppCredentialsFile

# Build lookup: source app/display name → new credentials
$credLookup = @{}
foreach ($cred in $appCredentials) {
    $credLookup[$cred.DisplayName] = $cred
    if ($cred.SourceAppId) {
        $credLookup[$cred.SourceAppId] = $cred
    }
}

Write-Host "  Service connections: $($serviceConnections.Count)" -ForegroundColor Green
Write-Host "  Available credentials: $($appCredentials.Count)" -ForegroundColor Green

# ── Update service connections ────────────────────────────────────────────
Write-Host "[2/2] Updating service connections..." -ForegroundColor Yellow

$results = @()
$updated = 0
$skipped = 0
$failed = 0

foreach ($sc in $serviceConnections) {
    # Skip non-Azure RM connections
    if ($sc.EndpointType -ne "azurerm") {
        $results += [PSCustomObject]@{
            ProjectName    = $sc.ProjectName
            EndpointName   = $sc.EndpointName
            EndpointType   = $sc.EndpointType
            Status         = "Skipped (not Azure RM)"
        }
        $skipped++
        continue
    }

    # Try to find matching new credentials
    $newCreds = $credLookup[$sc.EndpointName]
    if (-not $newCreds -and $sc.ServicePrincipalId) {
        $newCreds = $credLookup[$sc.ServicePrincipalId]
    }

    if (-not $newCreds) {
        $results += [PSCustomObject]@{
            ProjectName    = $sc.ProjectName
            EndpointName   = $sc.EndpointName
            EndpointType   = $sc.EndpointType
            Status         = "NoMatchingCredentials — Manual update required"
        }
        $skipped++
        Write-Host "  SKIP: $($sc.EndpointName) in $($sc.ProjectName) — no matching credentials" -ForegroundColor Yellow
        continue
    }

    if ($PSCmdlet.ShouldProcess("$($sc.EndpointName) in $($sc.ProjectName)", "Update service connection")) {
        try {
            # Get the current endpoint details via REST API
            $epDetail = az devops service-endpoint show `
                --id $sc.EndpointId `
                --org $orgUrl `
                --project $sc.ProjectName `
                -o json | ConvertFrom-Json

            # Update the authorization parameters
            $epDetail.authorization.parameters.serviceprincipalid = $newCreds.NewAppId
            $epDetail.authorization.parameters.serviceprincipalkey = $newCreds.ClientSecret
            $epDetail.authorization.parameters.tenantid = $TargetTenantId

            # Convert to JSON and update via REST API
            $body = $epDetail | ConvertTo-Json -Depth 10

            # Use REST API to update the endpoint
            $pat = az account get-access-token --resource "499b84ac-1321-427f-aa17-267ca6975798" -o tsv --query accessToken
            $headers = @{
                "Authorization" = "Bearer $pat"
                "Content-Type"  = "application/json"
            }

            $updateUri = "$orgUrl/$($sc.ProjectName)/_apis/serviceendpoint/endpoints/$($sc.EndpointId)?api-version=7.1"
            $response = Invoke-RestMethod -Uri $updateUri -Method Put -Headers $headers -Body $body

            $results += [PSCustomObject]@{
                ProjectName    = $sc.ProjectName
                EndpointName   = $sc.EndpointName
                EndpointType   = $sc.EndpointType
                Status         = "Updated"
            }
            $updated++
            Write-Host "  UPDATE: $($sc.EndpointName) in $($sc.ProjectName)" -ForegroundColor Green
        } catch {
            $results += [PSCustomObject]@{
                ProjectName    = $sc.ProjectName
                EndpointName   = $sc.EndpointName
                EndpointType   = $sc.EndpointType
                Status         = "Failed: $($_.Exception.Message)"
            }
            $failed++
            Write-Warning "  FAILED: $($sc.EndpointName) in $($sc.ProjectName) — $($_.Exception.Message)"
        }
    }
}

# ── Export results ──────────────────────────────────────────────────────────
$resultsFile = Join-Path $OutputPath "service-connection-update-results_${timestamp}.csv"
$results | Export-Csv -Path $resultsFile -NoTypeInformation -Encoding UTF8

Write-Host ""
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host " Service Connection Update Complete" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "  Updated   : $updated" -ForegroundColor Green
Write-Host "  Skipped   : $skipped" -ForegroundColor Yellow
Write-Host "  Failed    : $failed" -ForegroundColor $(if ($failed -gt 0) { "Red" } else { "Green" })
Write-Host "  Results   : $resultsFile" -ForegroundColor Green
Write-Host ""
Write-Host ">> Connections marked 'NoMatchingCredentials' must be updated manually." -ForegroundColor Yellow
Write-Host ">> Test all updated connections by running a pipeline that uses them." -ForegroundColor Yellow
