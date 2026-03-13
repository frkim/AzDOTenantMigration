<#
.SYNOPSIS
    Exports all Azure DevOps users with their access levels and licenses.

.DESCRIPTION
    Performs a complete inventory of all users in the Azure DevOps organization,
    including their UPNs, display names, access levels (Basic, Stakeholder,
    Visual Studio Subscriber, etc.), and license information.

    Output: CSV file with user details and a summary report.

.PARAMETER Organization
    The Azure DevOps organization name (e.g., "myorg" for https://dev.azure.com/myorg).

.PARAMETER OutputPath
    Directory where the export files will be saved. Defaults to ./output.

.PREREQUISITES
    - Azure CLI installed with Azure DevOps extension
    - Authenticated to Azure DevOps
    - Project Collection Administrator role

.EXAMPLE
    .\02-Export-Users.ps1 -Organization "myorg"

.NOTES
    Migration Phase : Pre-Migration
    Checklist Item  : #3 - Inventory all Azure DevOps users, access levels, and licenses
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
Write-Host " Export Azure DevOps Users — $orgUrl" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host ""

# ── Retrieve all users with pagination ──────────────────────────────────────
Write-Host "[1/2] Retrieving all organization users..." -ForegroundColor Yellow

$allUsers = @()
$top = 500
$skip = 0
$hasMore = $true

while ($hasMore) {
    $batch = az devops user list `
        --org $orgUrl `
        --top $top `
        --skip $skip `
        -o json | ConvertFrom-Json

    if ($batch.members -and $batch.members.Count -gt 0) {
        $allUsers += $batch.members
        $skip += $batch.members.Count
        Write-Host "  Retrieved $($allUsers.Count) of $($batch.totalCount) users..." -ForegroundColor Gray

        if ($allUsers.Count -ge $batch.totalCount) {
            $hasMore = $false
        }
    } else {
        $hasMore = $false
    }
}

Write-Host "  Total users retrieved: $($allUsers.Count)" -ForegroundColor Green

# ── Build export data ───────────────────────────────────────────────────────
Write-Host "[2/2] Processing user data..." -ForegroundColor Yellow

$userExport = $allUsers | ForEach-Object {
    [PSCustomObject]@{
        DisplayName        = $_.user.displayName
        PrincipalName      = $_.user.principalName
        MailAddress        = $_.user.mailAddress
        Origin             = $_.user.origin
        OriginId           = $_.user.originId
        SubjectKind        = $_.user.subjectKind
        AccessLevel        = $_.accessLevel.accountLicenseType
        AccessLevelStatus  = $_.accessLevel.licensingSource
        Status             = $_.accessLevel.status
        LastAccessedDate   = $_.lastAccessedDate
        DateCreated        = $_.dateCreated
    }
}

# ── Export to CSV ───────────────────────────────────────────────────────────
$usersFile = Join-Path $OutputPath "azdo-users_${timestamp}.csv"
$userExport | Export-Csv -Path $usersFile -NoTypeInformation -Encoding UTF8

# ── Generate summary ────────────────────────────────────────────────────────
$summary = $userExport | Group-Object AccessLevel | Sort-Object Count -Descending
$summaryFile = Join-Path $OutputPath "azdo-users-summary_${timestamp}.txt"

$summaryContent = @"
Azure DevOps User Inventory - $orgUrl
Generated: $(Get-Date -Format "yyyy-MM-dd HH:mm:ss")
============================================================

Total Users: $($userExport.Count)

Access Level Breakdown:
"@

foreach ($group in $summary) {
    $summaryContent += "`n  $($group.Name): $($group.Count)"
}

$summaryContent | Out-File -FilePath $summaryFile -Encoding UTF8

Write-Host ""
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host " Export Complete" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "  Users exported to   : $usersFile" -ForegroundColor Green
Write-Host "  Summary exported to : $summaryFile" -ForegroundColor Green
Write-Host ""
Write-Host "  Access Level Breakdown:" -ForegroundColor White
foreach ($group in $summary) {
    Write-Host "    $($group.Name): $($group.Count)" -ForegroundColor White
}
Write-Host ""
Write-Host ">> Ensure all users have corresponding accounts in the target tenant." -ForegroundColor Yellow
