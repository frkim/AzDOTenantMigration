<#
.SYNOPSIS
    Assigns Azure RBAC roles to new service principals in the target tenant.

.DESCRIPTION
    Reads the RBAC role assignment inventory exported from the source tenant and
    the app registration credentials from the target tenant, then creates matching
    RBAC role assignments for the new service principals.

    Output: CSV file with RBAC assignment results.

.PARAMETER SourceRBACFile
    Path to the CSV file exported by 08-Export-RBACAssignments.ps1 (rbac-assignments_*.csv).

.PARAMETER AppCredentialsFile
    Path to the CSV file exported by 04-Create-AppRegistrations.ps1 (app-credentials_*.csv).

.PARAMETER WhatIf
    If specified, generates the plan without creating assignments.

.PARAMETER OutputPath
    Directory where the export files will be saved. Defaults to ./output.

.PREREQUISITES
    - Azure CLI installed and authenticated
    - Owner or User Access Administrator role on the target subscriptions

.EXAMPLE
    .\05-Assign-RBACRoles.ps1 -SourceRBACFile "./output/rbac-assignments.csv" -AppCredentialsFile "./output/app-credentials.csv"

.NOTES
    Migration Phase : Preparation
    Checklist Item  : #8 - Assign Azure RBAC roles to new service principals
    Author          : Migration Team
    Date            : 2026-03-13
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory = $true)]
    [string]$SourceRBACFile,

    [Parameter(Mandatory = $true)]
    [string]$AppCredentialsFile,

    [Parameter(Mandatory = $false)]
    [string]$OutputPath = "./output"
)

$ErrorActionPreference = "Stop"
$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"

if (-not (Test-Path $OutputPath)) {
    New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null
}

Write-Host "============================================================" -ForegroundColor Cyan
Write-Host " Assign RBAC Roles to New Service Principals" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host ""

# ── Load data ─────────────────────────────────────────────────────────────
Write-Host "[1/2] Loading source RBAC assignments and app credentials..." -ForegroundColor Yellow

$sourceRBAC = Import-Csv -Path $SourceRBACFile
$appCredentials = Import-Csv -Path $AppCredentialsFile

# Build lookup: source app name or ID → new SP Object ID
$spLookup = @{}
foreach ($cred in $appCredentials) {
    $spLookup[$cred.DisplayName] = $cred.SPObjectId
    if ($cred.SourceAppId) {
        $spLookup[$cred.SourceAppId] = $cred.SPObjectId
    }
}

Write-Host "  Source RBAC assignments: $($sourceRBAC.Count)" -ForegroundColor Green
Write-Host "  New service principals: $($appCredentials.Count)" -ForegroundColor Green

# ── Create RBAC assignments ───────────────────────────────────────────────
Write-Host "[2/2] Creating RBAC role assignments..." -ForegroundColor Yellow

$results = @()
$assigned = 0
$skippedNoMatch = 0
$failed = 0

foreach ($assignment in $sourceRBAC) {
    # Try to find the new SP for this assignment
    $newSpObjectId = $spLookup[$assignment.PrincipalName]

    if (-not $newSpObjectId) {
        $results += [PSCustomObject]@{
            SourcePrincipalName = $assignment.PrincipalName
            RoleDefinition      = $assignment.RoleDefinition
            Scope               = $assignment.Scope
            NewSPObjectId       = ""
            Status              = "NoMatchingNewSP"
        }
        $skippedNoMatch++
        Write-Host "  SKIP: No matching new SP for '$($assignment.PrincipalName)'" -ForegroundColor Gray
        continue
    }

    if ($PSCmdlet.ShouldProcess("$($assignment.RoleDefinition) on $($assignment.Scope)", "Assign to SP $newSpObjectId")) {
        try {
            az role assignment create `
                --assignee-object-id $newSpObjectId `
                --assignee-principal-type ServicePrincipal `
                --role $assignment.RoleDefinition `
                --scope $assignment.Scope `
                -o none

            $results += [PSCustomObject]@{
                SourcePrincipalName = $assignment.PrincipalName
                RoleDefinition      = $assignment.RoleDefinition
                Scope               = $assignment.Scope
                NewSPObjectId       = $newSpObjectId
                Status              = "Assigned"
            }
            $assigned++
            Write-Host "  ASSIGN: $($assignment.RoleDefinition) → SP $newSpObjectId on $($assignment.Scope)" -ForegroundColor Green
        } catch {
            $results += [PSCustomObject]@{
                SourcePrincipalName = $assignment.PrincipalName
                RoleDefinition      = $assignment.RoleDefinition
                Scope               = $assignment.Scope
                NewSPObjectId       = $newSpObjectId
                Status              = "Failed: $($_.Exception.Message)"
            }
            $failed++
            Write-Warning "  FAILED: $($assignment.RoleDefinition) on $($assignment.Scope)"
        }
    }
}

# ── Export results ──────────────────────────────────────────────────────────
$resultsFile = Join-Path $OutputPath "rbac-assignment-results_${timestamp}.csv"
$results | Export-Csv -Path $resultsFile -NoTypeInformation -Encoding UTF8

Write-Host ""
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host " RBAC Assignment Complete" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "  Assigned       : $assigned" -ForegroundColor Green
Write-Host "  No match       : $skippedNoMatch" -ForegroundColor Yellow
Write-Host "  Failed         : $failed" -ForegroundColor $(if ($failed -gt 0) { "Red" } else { "Green" })
Write-Host "  Results file   : $resultsFile" -ForegroundColor Green
Write-Host ""
Write-Host ">> Review 'NoMatchingNewSP' entries — these may need manual RBAC assignment." -ForegroundColor Yellow
