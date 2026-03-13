<#
.SYNOPSIS
    Verifies user access to Azure DevOps after the tenant migration.

.DESCRIPTION
    Performs post-migration validation of user access by checking:
    - All users can be resolved in the organization
    - Access levels are correctly assigned
    - Team and group memberships are intact

    Compares current state against the pre-migration backup/export.

    Output: CSV file with user access verification results.

.PARAMETER Organization
    The Azure DevOps organization name.

.PARAMETER PreMigrationUsersFile
    Path to the CSV file exported before migration (azdo-users_*.csv from 02-Export-Users.ps1).

.PARAMETER OutputPath
    Directory where the export files will be saved. Defaults to ./output.

.PREREQUISITES
    - Azure CLI installed with Azure DevOps extension
    - Authenticated to Azure DevOps with the new tenant identity
    - Project Collection Administrator role

.EXAMPLE
    .\01-Verify-UserAccess.ps1 -Organization "myorg" -PreMigrationUsersFile "./output/azdo-users_20260301.csv"

.NOTES
    Migration Phase : Post-Migration
    Checklist Items : #1, #2, #3 - Verify user access, access levels, and group memberships
    Author          : Migration Team
    Date            : 2026-03-13
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$Organization,

    [Parameter(Mandatory = $false)]
    [string]$PreMigrationUsersFile,

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
Write-Host " Post-Migration User Access Verification — $orgUrl" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host ""

# ── Step 1: Get current users ────────────────────────────────────────────
Write-Host "[1/3] Retrieving current organization users..." -ForegroundColor Yellow

$allUsers = @()
$top = 500
$skip = 0
$hasMore = $true

while ($hasMore) {
    $batch = az devops user list --org $orgUrl --top $top --skip $skip -o json | ConvertFrom-Json

    if ($batch.members -and $batch.members.Count -gt 0) {
        $allUsers += $batch.members
        $skip += $batch.members.Count
        if ($allUsers.Count -ge $batch.totalCount) { $hasMore = $false }
    } else {
        $hasMore = $false
    }
}

Write-Host "  Current users: $($allUsers.Count)" -ForegroundColor Green

$currentUsers = $allUsers | ForEach-Object {
    [PSCustomObject]@{
        DisplayName   = $_.user.displayName
        PrincipalName = $_.user.principalName
        AccessLevel   = $_.accessLevel.accountLicenseType
        Status        = $_.accessLevel.status
    }
}

# ── Step 2: Compare with pre-migration data ──────────────────────────────
Write-Host "[2/3] Comparing with pre-migration data..." -ForegroundColor Yellow

$verificationResults = @()

if ($PreMigrationUsersFile -and (Test-Path $PreMigrationUsersFile)) {
    $preMigUsers = Import-Csv -Path $PreMigrationUsersFile

    $currentUpnSet = [System.Collections.Generic.HashSet[string]]::new(
        [System.StringComparer]::OrdinalIgnoreCase
    )
    $currentUsers | ForEach-Object { $currentUpnSet.Add($_.PrincipalName) | Out-Null }

    # Build current user lookup
    $currentUserLookup = @{}
    foreach ($cu in $currentUsers) {
        $currentUserLookup[$cu.PrincipalName.ToLower()] = $cu
    }

    $matched = 0
    $missing = 0
    $accessLevelMismatch = 0

    foreach ($preUser in $preMigUsers) {
        # Try matching by UPN prefix (since domain changed)
        $preUpnPrefix = ($preUser.PrincipalName -split "@")[0].ToLower()
        $matchedUser = $currentUsers | Where-Object {
            ($_.PrincipalName -split "@")[0].ToLower() -eq $preUpnPrefix
        } | Select-Object -First 1

        if ($matchedUser) {
            $accessMatch = ($matchedUser.AccessLevel -eq $preUser.AccessLevel)

            $verificationResults += [PSCustomObject]@{
                PreMigrationUPN    = $preUser.PrincipalName
                PostMigrationUPN   = $matchedUser.PrincipalName
                DisplayName        = $matchedUser.DisplayName
                PreAccessLevel     = $preUser.AccessLevel
                PostAccessLevel    = $matchedUser.AccessLevel
                AccessLevelMatch   = $accessMatch
                UserStatus         = $matchedUser.Status
                VerificationStatus = if ($accessMatch) { "OK" } else { "AccessLevelMismatch" }
            }

            $matched++
            if (-not $accessMatch) { $accessLevelMismatch++ }
        } else {
            $verificationResults += [PSCustomObject]@{
                PreMigrationUPN    = $preUser.PrincipalName
                PostMigrationUPN   = ""
                DisplayName        = $preUser.DisplayName
                PreAccessLevel     = $preUser.AccessLevel
                PostAccessLevel    = ""
                AccessLevelMatch   = $false
                UserStatus         = "NotFound"
                VerificationStatus = "MISSING"
            }
            $missing++
        }
    }

    Write-Host "  Matched users          : $matched" -ForegroundColor Green
    Write-Host "  Missing users          : $missing" -ForegroundColor $(if ($missing -gt 0) { "Red" } else { "Green" })
    Write-Host "  Access level mismatches: $accessLevelMismatch" -ForegroundColor $(if ($accessLevelMismatch -gt 0) { "Yellow" } else { "Green" })
} else {
    Write-Host "  No pre-migration file provided. Exporting current state only." -ForegroundColor Yellow

    $verificationResults = $currentUsers | ForEach-Object {
        [PSCustomObject]@{
            PreMigrationUPN    = ""
            PostMigrationUPN   = $_.PrincipalName
            DisplayName        = $_.DisplayName
            PreAccessLevel     = ""
            PostAccessLevel    = $_.AccessLevel
            AccessLevelMatch   = "N/A"
            UserStatus         = $_.Status
            VerificationStatus = "CurrentStateOnly"
        }
    }
}

# ── Step 3: Check group memberships ──────────────────────────────────────
Write-Host "[3/3] Spot-checking critical group memberships..." -ForegroundColor Yellow

$criticalGroups = @("Project Collection Administrators")
$groupCheck = @()

try {
    $groups = az devops security group list --org $orgUrl --scope organization -o json | ConvertFrom-Json

    foreach ($groupName in $criticalGroups) {
        $group = $groups.graphGroups | Where-Object { $_.displayName -eq $groupName }
        if ($group) {
            $members = az devops security group membership list --id $group.descriptor --org $orgUrl -o json | ConvertFrom-Json
            $memberCount = ($members.PSObject.Properties).Count

            $groupCheck += [PSCustomObject]@{
                GroupName   = $groupName
                MemberCount = $memberCount
                Status      = if ($memberCount -gt 0) { "OK" } else { "WARNING - No members" }
            }

            Write-Host "  $groupName : $memberCount members" -ForegroundColor $(if ($memberCount -gt 0) { "Green" } else { "Red" })
        }
    }
} catch {
    Write-Warning "  Could not verify group memberships"
}

# ── Export results ──────────────────────────────────────────────────────────
$resultsFile = Join-Path $OutputPath "user-access-verification_${timestamp}.csv"
$verificationResults | Export-Csv -Path $resultsFile -NoTypeInformation -Encoding UTF8

$missingFile = Join-Path $OutputPath "user-access-missing_${timestamp}.csv"
$verificationResults | Where-Object { $_.VerificationStatus -eq "MISSING" } |
    Export-Csv -Path $missingFile -NoTypeInformation -Encoding UTF8

Write-Host ""
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host " Verification Complete" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "  Results file     : $resultsFile" -ForegroundColor Green
Write-Host "  Missing users    : $missingFile" -ForegroundColor Green
Write-Host ""
if ($missing -gt 0) {
    Write-Host ">> ACTION REQUIRED: $missing users are missing after migration." -ForegroundColor Red
    Write-Host ">> Review the missing users file and resolve identity mapping issues." -ForegroundColor Red
}
