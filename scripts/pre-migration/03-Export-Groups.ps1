<#
.SYNOPSIS
    Exports all Azure DevOps groups and their memberships.

.DESCRIPTION
    Inventories all Azure DevOps security groups (both Entra ID-backed and
    AzDO-managed) across the organization and all projects, including their
    members and nesting relationships.

    Output: CSV files with group details and group memberships.

.PARAMETER Organization
    The Azure DevOps organization name.

.PARAMETER OutputPath
    Directory where the export files will be saved. Defaults to ./output.

.PREREQUISITES
    - Azure CLI installed with Azure DevOps extension
    - Authenticated to Azure DevOps
    - Project Collection Administrator role

.EXAMPLE
    .\03-Export-Groups.ps1 -Organization "myorg"

.NOTES
    Migration Phase : Pre-Migration
    Checklist Item  : #4 - Inventory all Azure DevOps groups
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
Write-Host " Export Azure DevOps Groups — $orgUrl" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host ""

# ── Step 1: Export Organization-level groups ────────────────────────────────
Write-Host "[1/3] Retrieving organization-level groups..." -ForegroundColor Yellow

$orgGroups = az devops security group list `
    --org $orgUrl `
    --scope organization `
    -o json | ConvertFrom-Json

$allGroups = @()
$allMemberships = @()

foreach ($group in $orgGroups.graphGroups) {
    $allGroups += [PSCustomObject]@{
        Scope        = "Organization"
        ProjectName  = ""
        DisplayName  = $group.displayName
        Description  = $group.description
        Origin       = $group.origin
        Descriptor   = $group.descriptor
        SubjectKind  = $group.subjectKind
    }

    # Get members of each group
    try {
        $members = az devops security group membership list `
            --id $group.descriptor `
            --org $orgUrl `
            -o json | ConvertFrom-Json

        foreach ($memberKey in $members.PSObject.Properties.Name) {
            $member = $members.$memberKey
            $allMemberships += [PSCustomObject]@{
                GroupScope       = "Organization"
                GroupProject     = ""
                GroupDisplayName = $group.displayName
                MemberName       = $member.displayName
                MemberPrincipal  = $member.principalName
                MemberMail       = $member.mailAddress
                MemberKind       = $member.subjectKind
                MemberOrigin     = $member.origin
            }
        }
    } catch {
        Write-Warning "  Could not retrieve members for group: $($group.displayName)"
    }
}

Write-Host "  Organization groups: $($orgGroups.graphGroups.Count)" -ForegroundColor Green

# ── Step 2: Export Project-level groups ─────────────────────────────────────
Write-Host "[2/3] Retrieving project-level groups..." -ForegroundColor Yellow

$projects = az devops project list --org $orgUrl -o json | ConvertFrom-Json

foreach ($project in $projects.value) {
    Write-Host "  Processing project: $($project.name)..." -ForegroundColor Gray

    try {
        $projectGroups = az devops security group list `
            --org $orgUrl `
            --scope project `
            --project $project.name `
            -o json | ConvertFrom-Json

        foreach ($group in $projectGroups.graphGroups) {
            $allGroups += [PSCustomObject]@{
                Scope        = "Project"
                ProjectName  = $project.name
                DisplayName  = $group.displayName
                Description  = $group.description
                Origin       = $group.origin
                Descriptor   = $group.descriptor
                SubjectKind  = $group.subjectKind
            }

            try {
                $members = az devops security group membership list `
                    --id $group.descriptor `
                    --org $orgUrl `
                    -o json | ConvertFrom-Json

                foreach ($memberKey in $members.PSObject.Properties.Name) {
                    $member = $members.$memberKey
                    $allMemberships += [PSCustomObject]@{
                        GroupScope       = "Project"
                        GroupProject     = $project.name
                        GroupDisplayName = $group.displayName
                        MemberName       = $member.displayName
                        MemberPrincipal  = $member.principalName
                        MemberMail       = $member.mailAddress
                        MemberKind       = $member.subjectKind
                        MemberOrigin     = $member.origin
                    }
                }
            } catch {
                Write-Warning "    Could not retrieve members for: $($group.displayName)"
            }
        }
    } catch {
        Write-Warning "  Could not retrieve groups for project: $($project.name)"
    }
}

# ── Step 3: Export results ──────────────────────────────────────────────────
Write-Host "[3/3] Exporting results..." -ForegroundColor Yellow

$groupsFile = Join-Path $OutputPath "azdo-groups_${timestamp}.csv"
$membershipsFile = Join-Path $OutputPath "azdo-group-memberships_${timestamp}.csv"

$allGroups | Export-Csv -Path $groupsFile -NoTypeInformation -Encoding UTF8
$allMemberships | Export-Csv -Path $membershipsFile -NoTypeInformation -Encoding UTF8

# Identify Entra ID-backed groups (important for recreation in target tenant)
$entraGroups = $allGroups | Where-Object { $_.Origin -eq "aad" }
$entraGroupsFile = Join-Path $OutputPath "azdo-entra-groups_${timestamp}.csv"
$entraGroups | Export-Csv -Path $entraGroupsFile -NoTypeInformation -Encoding UTF8

Write-Host ""
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host " Export Complete" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "  Total groups         : $($allGroups.Count)" -ForegroundColor Green
Write-Host "  Entra ID groups      : $($entraGroups.Count)" -ForegroundColor Green
Write-Host "  Total memberships    : $($allMemberships.Count)" -ForegroundColor Green
Write-Host "  Groups file          : $groupsFile" -ForegroundColor Green
Write-Host "  Memberships file     : $membershipsFile" -ForegroundColor Green
Write-Host "  Entra groups file    : $entraGroupsFile" -ForegroundColor Green
Write-Host ""
Write-Host ">> Entra ID-backed groups must be recreated in the target tenant." -ForegroundColor Yellow
Write-Host ">> AzDO-managed groups persist but their members need re-mapping." -ForegroundColor Yellow
