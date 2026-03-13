<#
.SYNOPSIS
    Cleans up source tenant resources after successful migration validation.

.DESCRIPTION
    After the migration is fully validated and the stabilization period has passed,
    this script helps clean up resources in the source tenant (contoso.com):
    - Lists temporary admin accounts created for migration
    - Lists old service principals that can be removed
    - Generates a cleanup report for manual review before deletion

    IMPORTANT: This script does NOT delete anything by default. It generates a report
    for review. Use the -Execute switch to perform actual deletions.

    Output: CSV file with resources identified for cleanup.

.PARAMETER SourceTenantId
    The tenant ID or domain of the source Entra ID tenant (e.g., "contoso.com").

.PARAMETER MigrationTag
    A tag or naming convention used to identify migration-related temporary resources
    (e.g., "migration-temp", "azdo-migration").

.PARAMETER Execute
    If specified, performs actual deletion of identified resources. USE WITH CAUTION.

.PARAMETER OutputPath
    Directory where the export files will be saved. Defaults to ./output.

.PREREQUISITES
    - Microsoft Graph PowerShell SDK
    - Global Administrator or Application Administrator role on the source tenant

.EXAMPLE
    # Review only (no deletions)
    .\01-Cleanup-SourceTenant.ps1 -SourceTenantId "contoso.com" -MigrationTag "migration-temp"

    # Execute cleanup (with confirmation)
    .\01-Cleanup-SourceTenant.ps1 -SourceTenantId "contoso.com" -MigrationTag "migration-temp" -Execute

.NOTES
    Migration Phase : Cleanup
    Checklist Items : #1, #2 - Remove temporary accounts and old service principals
    Author          : Migration Team
    Date            : 2026-03-13
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory = $true)]
    [string]$SourceTenantId,

    [Parameter(Mandatory = $false)]
    [string]$MigrationTag = "migration",

    [Parameter(Mandatory = $false)]
    [switch]$Execute,

    [Parameter(Mandatory = $false)]
    [string]$OutputPath = "./output"
)

$ErrorActionPreference = "Stop"
$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"

if (-not (Test-Path $OutputPath)) {
    New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null
}

Write-Host "============================================================" -ForegroundColor Cyan
Write-Host " Cleanup Source Tenant — $SourceTenantId" -ForegroundColor Cyan
Write-Host " Mode: $(if ($Execute) { '** EXECUTE — Resources will be DELETED **' } else { 'REVIEW ONLY (dry run)' })" -ForegroundColor $(if ($Execute) { "Red" } else { "Cyan" })
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host ""

if ($Execute) {
    Write-Host "  !! WARNING: Execute mode is enabled. Resources WILL be deleted. !!" -ForegroundColor Red
    $confirm = Read-Host "  Type 'YES' to confirm execution"
    if ($confirm -ne "YES") {
        Write-Host "  Execution cancelled." -ForegroundColor Yellow
        return
    }
}

# ── Connect to source tenant ──────────────────────────────────────────────
Write-Host "[1/4] Connecting to source tenant..." -ForegroundColor Yellow

Connect-MgGraph -TenantId $SourceTenantId -Scopes "User.ReadWrite.All", "Application.ReadWrite.All" -NoWelcome

# ── Step 2: Identify temporary migration accounts ────────────────────────
Write-Host "[2/4] Identifying temporary migration accounts..." -ForegroundColor Yellow

$allUsers = Get-MgUser -All -Property Id, DisplayName, UserPrincipalName, CreatedDateTime
$tempAccounts = $allUsers | Where-Object {
    $_.DisplayName -like "*$MigrationTag*" -or
    $_.UserPrincipalName -like "*$MigrationTag*"
}

$cleanupItems = @()

foreach ($account in $tempAccounts) {
    $action = "Review"
    if ($Execute -and $PSCmdlet.ShouldProcess($account.UserPrincipalName, "Delete temporary account")) {
        try {
            Remove-MgUser -UserId $account.Id
            $action = "Deleted"
            Write-Host "  DELETED: $($account.UserPrincipalName)" -ForegroundColor Red
        } catch {
            $action = "Failed: $($_.Exception.Message)"
            Write-Warning "  FAILED to delete: $($account.UserPrincipalName)"
        }
    } else {
        Write-Host "  FOUND: $($account.UserPrincipalName) (temp account)" -ForegroundColor Yellow
    }

    $cleanupItems += [PSCustomObject]@{
        ResourceType = "User"
        DisplayName  = $account.DisplayName
        Identifier   = $account.UserPrincipalName
        ObjectId     = $account.Id
        Created      = $account.CreatedDateTime
        Action       = $action
    }
}

Write-Host "  Temporary accounts found: $($tempAccounts.Count)" -ForegroundColor Green

# ── Step 3: Identify old AzDO-related app registrations ──────────────────
Write-Host "[3/4] Identifying AzDO-related app registrations..." -ForegroundColor Yellow

$allApps = Get-MgApplication -All -Property Id, AppId, DisplayName, CreatedDateTime
$azdoApps = $allApps | Where-Object {
    $_.DisplayName -like "*AzDevOps*" -or
    $_.DisplayName -like "*Azure DevOps*" -or
    $_.DisplayName -like "*ServiceConnection*" -or
    $_.DisplayName -like "*$MigrationTag*"
}

foreach ($app in $azdoApps) {
    $action = "Review"
    if ($Execute -and $PSCmdlet.ShouldProcess($app.DisplayName, "Delete app registration")) {
        try {
            Remove-MgApplication -ApplicationId $app.Id
            $action = "Deleted"
            Write-Host "  DELETED: $($app.DisplayName)" -ForegroundColor Red
        } catch {
            $action = "Failed: $($_.Exception.Message)"
            Write-Warning "  FAILED to delete: $($app.DisplayName)"
        }
    } else {
        Write-Host "  FOUND: $($app.DisplayName) (app registration)" -ForegroundColor Yellow
    }

    $cleanupItems += [PSCustomObject]@{
        ResourceType = "AppRegistration"
        DisplayName  = $app.DisplayName
        Identifier   = $app.AppId
        ObjectId     = $app.Id
        Created      = $app.CreatedDateTime
        Action       = $action
    }
}

Write-Host "  AzDO-related app registrations found: $($azdoApps.Count)" -ForegroundColor Green

# ── Step 4: Generate cleanup report ──────────────────────────────────────
Write-Host "[4/4] Generating cleanup report..." -ForegroundColor Yellow

$reportFile = Join-Path $OutputPath "cleanup-report_${timestamp}.csv"
$cleanupItems | Export-Csv -Path $reportFile -NoTypeInformation -Encoding UTF8

Disconnect-MgGraph | Out-Null

Write-Host ""
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host " Cleanup $(if ($Execute) { 'Execution' } else { 'Report' }) Complete" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "  Temp accounts        : $($tempAccounts.Count)" -ForegroundColor White
Write-Host "  App registrations    : $($azdoApps.Count)" -ForegroundColor White
Write-Host "  Total items          : $($cleanupItems.Count)" -ForegroundColor White
Write-Host "  Report file          : $reportFile" -ForegroundColor Green
Write-Host ""
if (-not $Execute) {
    Write-Host ">> This was a DRY RUN. No resources were modified." -ForegroundColor Yellow
    Write-Host ">> Review the report and run with -Execute to perform actual cleanup." -ForegroundColor Yellow
} else {
    Write-Host ">> Cleanup completed. Verify no critical resources were removed." -ForegroundColor Yellow
}
