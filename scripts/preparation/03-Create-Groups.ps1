<#
.SYNOPSIS
    Recreates Entra ID security groups and Microsoft 365 groups in the target tenant.

.DESCRIPTION
    Reads the group inventory exported from the source tenant and recreates
    the groups in the target tenant (zava.com), then populates group memberships
    based on the exported membership data and UPN mapping.

    Output: CSV file with group creation results and membership population status.

.PARAMETER SourceGroupsFile
    Path to the CSV file exported by 07-Export-EntraIDInventory.ps1 (entra-groups_*.csv).

.PARAMETER SourceMembershipsFile
    Path to the CSV file exported by 07-Export-EntraIDInventory.ps1 (entra-group-memberships_*.csv).

.PARAMETER TargetTenantId
    The tenant ID or domain of the target Entra ID tenant (e.g., "zava.com").

.PARAMETER TargetDomain
    The target domain for UPN mapping (e.g., "zava.com").

.PARAMETER WhatIf
    If specified, generates the plan without creating groups.

.PARAMETER OutputPath
    Directory where the export files will be saved. Defaults to ./output.

.PREREQUISITES
    - Microsoft Graph PowerShell SDK
    - Group.ReadWrite.All, GroupMember.ReadWrite.All permissions on the target tenant

.EXAMPLE
    # Preview only
    .\03-Create-Groups.ps1 -SourceGroupsFile "./output/entra-groups.csv" -SourceMembershipsFile "./output/entra-group-memberships.csv" -TargetTenantId "zava.com" -TargetDomain "zava.com" -WhatIf

    # Create groups
    .\03-Create-Groups.ps1 -SourceGroupsFile "./output/entra-groups.csv" -SourceMembershipsFile "./output/entra-group-memberships.csv" -TargetTenantId "zava.com" -TargetDomain "zava.com"

.NOTES
    Migration Phase : Preparation
    Checklist Items : #3, #4, #5 - Recreate groups and populate memberships
    Author          : Migration Team
    Date            : 2026-03-13
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory = $true)]
    [string]$SourceGroupsFile,

    [Parameter(Mandatory = $true)]
    [string]$SourceMembershipsFile,

    [Parameter(Mandatory = $true)]
    [string]$TargetTenantId,

    [Parameter(Mandatory = $true)]
    [string]$TargetDomain,

    [Parameter(Mandatory = $false)]
    [string]$OutputPath = "./output"
)

$ErrorActionPreference = "Stop"
$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"

if (-not (Test-Path $OutputPath)) {
    New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null
}

Write-Host "============================================================" -ForegroundColor Cyan
Write-Host " Create Groups in Target Tenant — $TargetDomain" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host ""

# ── Load source data ──────────────────────────────────────────────────────
Write-Host "[1/4] Loading source group inventory..." -ForegroundColor Yellow

$sourceGroups = Import-Csv -Path $SourceGroupsFile
$sourceMemberships = Import-Csv -Path $SourceMembershipsFile
Write-Host "  Source groups: $($sourceGroups.Count)" -ForegroundColor Green
Write-Host "  Source memberships: $($sourceMemberships.Count)" -ForegroundColor Green

# ── Connect to target tenant ──────────────────────────────────────────────
Write-Host "[2/4] Connecting to target tenant..." -ForegroundColor Yellow

Connect-MgGraph -TenantId $TargetTenantId -Scopes "Group.ReadWrite.All", "GroupMember.ReadWrite.All", "User.Read.All" -NoWelcome

# Build target user lookup by UPN prefix
$targetUsers = Get-MgUser -All -Property Id, UserPrincipalName
$targetUserByPrefix = @{}
foreach ($u in $targetUsers) {
    $prefix = ($u.UserPrincipalName -split "@")[0].ToLower()
    $targetUserByPrefix[$prefix] = $u
}

# Check existing groups in target
$existingGroups = Get-MgGroup -All -Property DisplayName, Id
$existingGroupNames = [System.Collections.Generic.HashSet[string]]::new(
    [System.StringComparer]::OrdinalIgnoreCase
)
$existingGroups | ForEach-Object { $existingGroupNames.Add($_.DisplayName) | Out-Null }

# ── Create groups ─────────────────────────────────────────────────────────
Write-Host "[3/4] Creating groups..." -ForegroundColor Yellow

$groupResults = @()
$groupIdMap = @{} # Maps source group display name to new group ID
$created = 0
$skipped = 0

foreach ($group in $sourceGroups) {
    $status = "Unknown"

    if ($existingGroupNames.Contains($group.DisplayName)) {
        $existingGroup = $existingGroups | Where-Object { $_.DisplayName -eq $group.DisplayName } | Select-Object -First 1
        $groupIdMap[$group.DisplayName] = $existingGroup.Id
        $status = "AlreadyExists"
        $skipped++
        Write-Host "  SKIP: $($group.DisplayName) (already exists)" -ForegroundColor Gray
    } elseif ($PSCmdlet.ShouldProcess($group.DisplayName, "Create group")) {
        try {
            $mailNickname = ($group.DisplayName -replace '[^a-zA-Z0-9]', '')
            if ([string]::IsNullOrEmpty($mailNickname)) { $mailNickname = "group$(Get-Random)" }

            $params = @{
                DisplayName     = $group.DisplayName
                Description     = $group.Description
                SecurityEnabled = [bool]($group.SecurityEnabled -eq "True")
                MailEnabled     = $false
                MailNickname    = $mailNickname
            }

            # Handle Microsoft 365 groups
            if ($group.GroupType -eq "Microsoft365") {
                $params.MailEnabled = $true
                $params.GroupTypes = @("Unified")
            }

            $newGroup = New-MgGroup @params
            $groupIdMap[$group.DisplayName] = $newGroup.Id
            $status = "Created"
            $created++
            Write-Host "  CREATE: $($group.DisplayName) ($($group.GroupType))" -ForegroundColor Green
        } catch {
            $status = "Failed: $($_.Exception.Message)"
            Write-Warning "  FAILED: $($group.DisplayName) — $($_.Exception.Message)"
        }
    }

    $groupResults += [PSCustomObject]@{
        DisplayName = $group.DisplayName
        GroupType   = $group.GroupType
        Status      = $status
    }
}

# ── Populate group memberships ────────────────────────────────────────────
Write-Host "[4/4] Populating group memberships..." -ForegroundColor Yellow

$membershipResults = @()
$memberAdded = 0
$memberFailed = 0

foreach ($membership in $sourceMemberships) {
    $groupId = $groupIdMap[$membership.GroupDisplayName]

    if (-not $groupId) {
        $membershipResults += [PSCustomObject]@{
            GroupDisplayName = $membership.GroupDisplayName
            MemberUPN        = $membership.MemberUPN
            Status           = "GroupNotFound"
        }
        continue
    }

    # Find target user by UPN prefix
    $memberUpnPrefix = ($membership.MemberUPN -split "@")[0].ToLower()
    $targetUser = $targetUserByPrefix[$memberUpnPrefix]

    if (-not $targetUser) {
        $membershipResults += [PSCustomObject]@{
            GroupDisplayName = $membership.GroupDisplayName
            MemberUPN        = $membership.MemberUPN
            Status           = "UserNotFoundInTarget"
        }
        $memberFailed++
        continue
    }

    if ($PSCmdlet.ShouldProcess("$($targetUser.UserPrincipalName) → $($membership.GroupDisplayName)", "Add member")) {
        try {
            New-MgGroupMember -GroupId $groupId -DirectoryObjectId $targetUser.Id
            $memberAdded++
            $membershipResults += [PSCustomObject]@{
                GroupDisplayName = $membership.GroupDisplayName
                MemberUPN        = $targetUser.UserPrincipalName
                Status           = "Added"
            }
        } catch {
            if ($_.Exception.Message -like "*already exist*") {
                $membershipResults += [PSCustomObject]@{
                    GroupDisplayName = $membership.GroupDisplayName
                    MemberUPN        = $targetUser.UserPrincipalName
                    Status           = "AlreadyMember"
                }
            } else {
                $memberFailed++
                $membershipResults += [PSCustomObject]@{
                    GroupDisplayName = $membership.GroupDisplayName
                    MemberUPN        = $targetUser.UserPrincipalName
                    Status           = "Failed: $($_.Exception.Message)"
                }
            }
        }
    }
}

# ── Export results ──────────────────────────────────────────────────────────
$groupResultsFile = Join-Path $OutputPath "group-creation-results_${timestamp}.csv"
$memberResultsFile = Join-Path $OutputPath "group-membership-results_${timestamp}.csv"

$groupResults | Export-Csv -Path $groupResultsFile -NoTypeInformation -Encoding UTF8
$membershipResults | Export-Csv -Path $memberResultsFile -NoTypeInformation -Encoding UTF8

Disconnect-MgGraph | Out-Null

Write-Host ""
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host " Group Creation Complete" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "  Groups created      : $created" -ForegroundColor Green
Write-Host "  Groups skipped      : $skipped" -ForegroundColor Yellow
Write-Host "  Members added       : $memberAdded" -ForegroundColor Green
Write-Host "  Members failed      : $memberFailed" -ForegroundColor $(if ($memberFailed -gt 0) { "Red" } else { "Green" })
Write-Host "  Group results file  : $groupResultsFile" -ForegroundColor Green
Write-Host "  Member results file : $memberResultsFile" -ForegroundColor Green
Write-Host ""
Write-Host ">> Review failed memberships — users may not exist in the target tenant." -ForegroundColor Yellow
