<#
.SYNOPSIS
    Creates app registrations and service principals in the target Entra ID tenant.

.DESCRIPTION
    Reads the app registration inventory exported from the source tenant and
    recreates app registrations and service principals in the target tenant.
    Generates client secrets for each app and exports the credentials securely.

    IMPORTANT: Client secrets are exported to a file. Secure this file appropriately.

    Output: CSV files with app registration details and credentials.

.PARAMETER SourceAppsFile
    Path to the CSV file exported by 07-Export-EntraIDInventory.ps1 (entra-app-registrations_*.csv).

.PARAMETER TargetTenantId
    The tenant ID or domain of the target Entra ID tenant (e.g., "zava.com").

.PARAMETER SecretValidityYears
    Number of years for client secret validity. Defaults to 1.

.PARAMETER WhatIf
    If specified, generates the plan without creating resources.

.PARAMETER OutputPath
    Directory where the export files will be saved. Defaults to ./output.

.PREREQUISITES
    - Microsoft Graph PowerShell SDK
    - Application.ReadWrite.All permission on the target tenant

.EXAMPLE
    .\04-Create-AppRegistrations.ps1 -SourceAppsFile "./output/entra-app-registrations.csv" -TargetTenantId "zava.com"

.NOTES
    Migration Phase : Preparation
    Checklist Items : #6, #7 - Create app registrations, service principals, and secrets
    Author          : Migration Team
    Date            : 2026-03-13
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory = $true)]
    [string]$SourceAppsFile,

    [Parameter(Mandatory = $true)]
    [string]$TargetTenantId,

    [Parameter(Mandatory = $false)]
    [int]$SecretValidityYears = 1,

    [Parameter(Mandatory = $false)]
    [string]$OutputPath = "./output"
)

$ErrorActionPreference = "Stop"
$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"

if (-not (Test-Path $OutputPath)) {
    New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null
}

Write-Host "============================================================" -ForegroundColor Cyan
Write-Host " Create App Registrations in Target Tenant" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host ""

# ── Load source apps ──────────────────────────────────────────────────────
Write-Host "[1/3] Loading source app registration inventory..." -ForegroundColor Yellow

$sourceApps = Import-Csv -Path $SourceAppsFile
Write-Host "  Source app registrations: $($sourceApps.Count)" -ForegroundColor Green

# ── Connect to target tenant ──────────────────────────────────────────────
Write-Host "[2/3] Connecting to target tenant..." -ForegroundColor Yellow

Connect-MgGraph -TenantId $TargetTenantId -Scopes "Application.ReadWrite.All" -NoWelcome

# Check existing apps
$existingApps = Get-MgApplication -All -Property DisplayName, AppId
$existingAppNames = [System.Collections.Generic.HashSet[string]]::new(
    [System.StringComparer]::OrdinalIgnoreCase
)
$existingApps | ForEach-Object { $existingAppNames.Add($_.DisplayName) | Out-Null }

# ── Create app registrations ─────────────────────────────────────────────
Write-Host "[3/3] Creating app registrations and service principals..." -ForegroundColor Yellow

$appResults = @()
$credentialResults = @()
$created = 0
$skipped = 0

foreach ($app in $sourceApps) {
    $status = "Unknown"

    if ($existingAppNames.Contains($app.DisplayName)) {
        $status = "AlreadyExists"
        $skipped++
        Write-Host "  SKIP: $($app.DisplayName) (already exists)" -ForegroundColor Gray
    } elseif ($PSCmdlet.ShouldProcess($app.DisplayName, "Create app registration")) {
        try {
            # Create app registration
            $newAppParams = @{
                DisplayName    = $app.DisplayName
                SignInAudience = if ($app.SignInAudience) { $app.SignInAudience } else { "AzureADMyOrg" }
            }

            # Add reply URLs if present
            if ($app.ReplyUrls) {
                $urls = $app.ReplyUrls -split "; " | Where-Object { $_ }
                if ($urls) {
                    $newAppParams.Web = @{ RedirectUris = $urls }
                }
            }

            $newApp = New-MgApplication @newAppParams

            # Create service principal
            $sp = New-MgServicePrincipal -AppId $newApp.AppId

            # Create client secret
            $secret = Add-MgApplicationPassword -ApplicationId $newApp.Id -PasswordCredential @{
                DisplayName = "Migration-generated"
                EndDateTime = (Get-Date).AddYears($SecretValidityYears)
            }

            $status = "Created"
            $created++

            Write-Host "  CREATE: $($app.DisplayName) (AppId: $($newApp.AppId))" -ForegroundColor Green

            # Store credentials (handle securely!)
            $credentialResults += [PSCustomObject]@{
                DisplayName        = $app.DisplayName
                SourceAppId        = $app.AppId
                NewAppId           = $newApp.AppId
                NewObjectId        = $newApp.Id
                SPObjectId         = $sp.Id
                ClientSecret       = $secret.SecretText
                SecretExpiry       = $secret.EndDateTime
            }
        } catch {
            $status = "Failed: $($_.Exception.Message)"
            Write-Warning "  FAILED: $($app.DisplayName) — $($_.Exception.Message)"
        }
    }

    $appResults += [PSCustomObject]@{
        SourceDisplayName = $app.DisplayName
        SourceAppId       = $app.AppId
        Status            = $status
    }
}

# ── Export results ──────────────────────────────────────────────────────────
$appResultsFile = Join-Path $OutputPath "app-registration-results_${timestamp}.csv"
$credentialsFile = Join-Path $OutputPath "app-credentials_${timestamp}.csv"

$appResults | Export-Csv -Path $appResultsFile -NoTypeInformation -Encoding UTF8
$credentialResults | Export-Csv -Path $credentialsFile -NoTypeInformation -Encoding UTF8

Disconnect-MgGraph | Out-Null

Write-Host ""
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host " App Registration Creation Complete" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "  Created       : $created" -ForegroundColor Green
Write-Host "  Skipped       : $skipped" -ForegroundColor Yellow
Write-Host "  Results file  : $appResultsFile" -ForegroundColor Green
Write-Host "  Credentials   : $credentialsFile" -ForegroundColor Green
Write-Host ""
Write-Host "  ** SECURITY WARNING **" -ForegroundColor Red
Write-Host "  The credentials file contains client secrets." -ForegroundColor Red
Write-Host "  Store it securely (e.g., Azure Key Vault) and delete after use." -ForegroundColor Red
Write-Host ""
Write-Host ">> Next: Assign RBAC roles to the new service principals (05-Assign-RBACRoles.ps1)." -ForegroundColor Yellow
