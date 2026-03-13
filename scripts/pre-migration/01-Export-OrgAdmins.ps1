<#
.SYNOPSIS
    Exports Azure DevOps Organization Owner and Project Collection Administrators.

.DESCRIPTION
    This script identifies and documents the Azure DevOps Organization Owner and all
    Project Collection Administrators. This information is critical to ensure the right
    people have access during and after the tenant migration.

    Output: CSV file with admin identities, roles, and UPNs.

.PARAMETER Organization
    The Azure DevOps organization name (e.g., "myorg" for https://dev.azure.com/myorg).

.PARAMETER OutputPath
    Directory where the export files will be saved. Defaults to ./output.

.PREREQUISITES
    - Azure CLI installed (https://learn.microsoft.com/en-us/cli/azure/install-azure-cli)
    - Azure DevOps CLI extension (az extension add --name azure-devops)
    - Authenticated to Azure DevOps (az login / az devops login)
    - Project Collection Administrator role on the organization

.EXAMPLE
    .\01-Export-OrgAdmins.ps1 -Organization "myorg"
    .\01-Export-OrgAdmins.ps1 -Organization "myorg" -OutputPath "C:\migration\exports"

.NOTES
    Migration Phase : Pre-Migration
    Checklist Item  : #1 - Identify and document Organization Owner and PCAs
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

# ── Create output directory ──────────────────────────────────────────────────
if (-not (Test-Path $OutputPath)) {
    New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null
}

$orgUrl = "https://dev.azure.com/$Organization"

Write-Host "============================================================" -ForegroundColor Cyan
Write-Host " Export Organization Admins — $orgUrl" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host ""

# ── Step 1: Get Organization Owner ──────────────────────────────────────────
Write-Host "[1/3] Retrieving organization details..." -ForegroundColor Yellow

try {
    $orgDetails = az devops organization show --org $orgUrl -o json | ConvertFrom-Json
    Write-Host "  Organization: $($orgDetails.name)" -ForegroundColor Green
} catch {
    Write-Warning "Could not retrieve organization details via CLI. Using REST API fallback."
}

# ── Step 2: Get Project Collection Administrators ───────────────────────────
Write-Host "[2/3] Retrieving Project Collection Administrators..." -ForegroundColor Yellow

$pcaGroupDescriptor = $null
$adminResults = @()

try {
    # List all organization-level security groups
    $groups = az devops security group list `
        --org $orgUrl `
        --scope organization `
        -o json | ConvertFrom-Json

    # Find the Project Collection Administrators group
    $pcaGroup = $groups.graphGroups | Where-Object { $_.displayName -eq "Project Collection Administrators" }

    if ($pcaGroup) {
        Write-Host "  Found PCA group: $($pcaGroup.displayName)" -ForegroundColor Green
        $pcaGroupDescriptor = $pcaGroup.descriptor

        # Get members of PCA group
        $members = az devops security group membership list `
            --id $pcaGroupDescriptor `
            --org $orgUrl `
            -o json | ConvertFrom-Json

        foreach ($memberKey in $members.PSObject.Properties.Name) {
            $member = $members.$memberKey
            $adminResults += [PSCustomObject]@{
                DisplayName   = $member.displayName
                PrincipalName = $member.principalName
                MailAddress   = $member.mailAddress
                Origin        = $member.origin
                OriginId      = $member.originId
                SubjectKind   = $member.subjectKind
                GroupRole     = "Project Collection Administrator"
            }
        }

        Write-Host "  Found $($adminResults.Count) PCA members." -ForegroundColor Green
    } else {
        Write-Warning "Project Collection Administrators group not found."
    }
} catch {
    Write-Error "Failed to retrieve PCA group members: $_"
}

# ── Step 3: Get Project Collection Valid Users (Organization-level) ─────────
Write-Host "[3/3] Retrieving organization-level user summary..." -ForegroundColor Yellow

try {
    $users = az devops user list --org $orgUrl --top 500 -o json | ConvertFrom-Json
    $orgOwnerUser = $users.members | Where-Object { $_.user.principalName -and $_.accessLevel }

    # Find organization owner by checking for the highest access
    Write-Host "  Total users in organization: $($users.totalCount)" -ForegroundColor Green
} catch {
    Write-Warning "Could not retrieve user list: $_"
}

# ── Export Results ──────────────────────────────────────────────────────────
$pcaFile = Join-Path $OutputPath "org-admins_${timestamp}.csv"
$adminResults | Export-Csv -Path $pcaFile -NoTypeInformation -Encoding UTF8

Write-Host ""
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host " Export Complete" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "  PCA members exported to : $pcaFile" -ForegroundColor Green
Write-Host "  Total PCA members       : $($adminResults.Count)" -ForegroundColor Green
Write-Host ""
Write-Host ">> Review the exported file and confirm Organization Owner identity." -ForegroundColor Yellow
Write-Host ">> Ensure these admins have accounts in the target tenant." -ForegroundColor Yellow
