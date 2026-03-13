<#
.SYNOPSIS
    Exports Azure RBAC role assignments for service principals.

.DESCRIPTION
    Documents all Azure RBAC role assignments associated with service principals
    from the source tenant. These assignments must be recreated for new service
    principals in the target tenant after migration.

    Output: CSV file with RBAC role assignment details.

.PARAMETER SubscriptionIds
    Array of Azure subscription IDs to scan. If not provided, scans all accessible subscriptions.

.PARAMETER OutputPath
    Directory where the export files will be saved. Defaults to ./output.

.PREREQUISITES
    - Azure CLI installed and authenticated (az login)
    - Reader role on the target subscriptions

.EXAMPLE
    .\08-Export-RBACAssignments.ps1
    .\08-Export-RBACAssignments.ps1 -SubscriptionIds @("sub-id-1", "sub-id-2")

.NOTES
    Migration Phase : Pre-Migration
    Checklist Item  : #10 - Document all Azure RBAC role assignments for service principals
    Author          : Migration Team
    Date            : 2026-03-13
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string[]]$SubscriptionIds,

    [Parameter(Mandatory = $false)]
    [string]$OutputPath = "./output"
)

$ErrorActionPreference = "Stop"
$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"

if (-not (Test-Path $OutputPath)) {
    New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null
}

Write-Host "============================================================" -ForegroundColor Cyan
Write-Host " Export Azure RBAC Assignments" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host ""

# ── Get subscriptions ──────────────────────────────────────────────────────
Write-Host "[1/2] Retrieving subscriptions..." -ForegroundColor Yellow

if (-not $SubscriptionIds) {
    $subs = az account list -o json | ConvertFrom-Json
    $SubscriptionIds = $subs | Where-Object { $_.state -eq "Enabled" } | Select-Object -ExpandProperty id
}

Write-Host "  Scanning $($SubscriptionIds.Count) subscription(s)." -ForegroundColor Green

# ── Retrieve RBAC assignments ──────────────────────────────────────────────
Write-Host "[2/2] Retrieving RBAC role assignments..." -ForegroundColor Yellow

$allAssignments = @()

foreach ($subId in $SubscriptionIds) {
    Write-Host "  Subscription: $subId..." -ForegroundColor Gray

    try {
        az account set --subscription $subId

        $assignments = az role assignment list `
            --all `
            --include-inherited `
            -o json | ConvertFrom-Json

        # Filter for service principal assignments
        $spAssignments = $assignments | Where-Object { $_.principalType -eq "ServicePrincipal" }

        foreach ($a in $spAssignments) {
            $allAssignments += [PSCustomObject]@{
                SubscriptionId  = $subId
                PrincipalId     = $a.principalId
                PrincipalName   = $a.principalName
                PrincipalType   = $a.principalType
                RoleDefinition  = $a.roleDefinitionName
                RoleId          = $a.roleDefinitionId
                Scope           = $a.scope
                Condition       = $a.condition
                CreatedOn       = $a.createdOn
            }
        }

        Write-Host "    Found $($spAssignments.Count) service principal assignments." -ForegroundColor Gray
    } catch {
        Write-Warning "    Could not retrieve assignments for subscription: $subId"
    }
}

# ── Export results ──────────────────────────────────────────────────────────
$assignmentsFile = Join-Path $OutputPath "rbac-assignments_${timestamp}.csv"
$allAssignments | Export-Csv -Path $assignmentsFile -NoTypeInformation -Encoding UTF8

# Summary by role
$roleSummary = $allAssignments | Group-Object RoleDefinition | Sort-Object Count -Descending

Write-Host ""
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host " Export Complete" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "  Total SP role assignments : $($allAssignments.Count)" -ForegroundColor Green
Write-Host "  Exported to               : $assignmentsFile" -ForegroundColor Green
Write-Host ""
Write-Host "  Role Breakdown:" -ForegroundColor White
foreach ($role in $roleSummary) {
    Write-Host "    $($role.Name): $($role.Count)" -ForegroundColor White
}
Write-Host ""
Write-Host ">> These RBAC assignments must be recreated for new service principals in the target tenant." -ForegroundColor Yellow
