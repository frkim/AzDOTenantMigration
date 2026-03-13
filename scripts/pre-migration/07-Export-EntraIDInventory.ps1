<#
.SYNOPSIS
    Exports Entra ID users, groups, and app registrations from the source tenant.

.DESCRIPTION
    Performs a comprehensive inventory of the source Entra ID tenant (contoso.com),
    exporting all users, security groups, group memberships, and app registrations.
    This data is used to plan and execute identity provisioning in the target tenant.

    Output: Multiple CSV files with Entra ID inventory data.

.PARAMETER SourceTenantId
    The tenant ID or domain of the source Entra ID tenant (e.g., "contoso.com").

.PARAMETER OutputPath
    Directory where the export files will be saved. Defaults to ./output.

.PREREQUISITES
    - Microsoft Graph PowerShell SDK (Install-Module Microsoft.Graph)
    - Global Reader or User Administrator role on the source tenant
    - Permissions: User.Read.All, Group.Read.All, Application.Read.All, GroupMember.Read.All

.EXAMPLE
    .\07-Export-EntraIDInventory.ps1 -SourceTenantId "contoso.com"
    .\07-Export-EntraIDInventory.ps1 -SourceTenantId "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"

.NOTES
    Migration Phase : Pre-Migration
    Checklist Item  : #3, #4, #10 - Inventory users, groups, and RBAC from source tenant
    Author          : Migration Team
    Date            : 2026-03-13
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$SourceTenantId,

    [Parameter(Mandatory = $false)]
    [string]$OutputPath = "./output"
)

$ErrorActionPreference = "Stop"
$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"

if (-not (Test-Path $OutputPath)) {
    New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null
}

Write-Host "============================================================" -ForegroundColor Cyan
Write-Host " Export Entra ID Inventory — $SourceTenantId" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host ""

# ── Connect to Microsoft Graph ─────────────────────────────────────────────
Write-Host "[1/5] Connecting to Microsoft Graph..." -ForegroundColor Yellow

$requiredScopes = @(
    "User.Read.All",
    "Group.Read.All",
    "GroupMember.Read.All",
    "Application.Read.All"
)

Connect-MgGraph -TenantId $SourceTenantId -Scopes $requiredScopes -NoWelcome
$context = Get-MgContext
Write-Host "  Connected as: $($context.Account) to tenant: $($context.TenantId)" -ForegroundColor Green

# ── Step 2: Export users ───────────────────────────────────────────────────
Write-Host "[2/5] Exporting users..." -ForegroundColor Yellow

$users = Get-MgUser -All -Property Id, DisplayName, UserPrincipalName, Mail, UserType, AccountEnabled, CreatedDateTime, Department, JobTitle

$userExport = $users | ForEach-Object {
    [PSCustomObject]@{
        Id                = $_.Id
        DisplayName       = $_.DisplayName
        UserPrincipalName = $_.UserPrincipalName
        Mail              = $_.Mail
        UserType          = $_.UserType
        AccountEnabled    = $_.AccountEnabled
        Department        = $_.Department
        JobTitle          = $_.JobTitle
        CreatedDateTime   = $_.CreatedDateTime
    }
}

$usersFile = Join-Path $OutputPath "entra-users_${timestamp}.csv"
$userExport | Export-Csv -Path $usersFile -NoTypeInformation -Encoding UTF8
Write-Host "  Exported $($userExport.Count) users." -ForegroundColor Green

# Separate member vs guest users
$memberUsers = $userExport | Where-Object { $_.UserType -eq "Member" }
$guestUsers = $userExport | Where-Object { $_.UserType -eq "Guest" }
Write-Host "  Members: $($memberUsers.Count) | Guests: $($guestUsers.Count)" -ForegroundColor Green

# ── Step 3: Export groups and memberships ──────────────────────────────────
Write-Host "[3/5] Exporting groups and memberships..." -ForegroundColor Yellow

$groups = Get-MgGroup -All -Property Id, DisplayName, Description, GroupTypes, SecurityEnabled, MailEnabled, Mail

$groupExport = @()
$membershipExport = @()

foreach ($group in $groups) {
    $groupType = if ($group.GroupTypes -contains "Unified") { "Microsoft365" }
                 elseif ($group.SecurityEnabled) { "Security" }
                 else { "Distribution" }

    $groupExport += [PSCustomObject]@{
        Id              = $group.Id
        DisplayName     = $group.DisplayName
        Description     = $group.Description
        GroupType       = $groupType
        SecurityEnabled = $group.SecurityEnabled
        MailEnabled     = $group.MailEnabled
        Mail            = $group.Mail
    }

    # Get group members
    try {
        $members = Get-MgGroupMember -GroupId $group.Id -All

        foreach ($member in $members) {
            $membershipExport += [PSCustomObject]@{
                GroupId          = $group.Id
                GroupDisplayName = $group.DisplayName
                GroupType        = $groupType
                MemberId         = $member.Id
                MemberType       = $member.AdditionalProperties.'@odata.type'
                MemberUPN        = $member.AdditionalProperties.userPrincipalName
                MemberDisplay    = $member.AdditionalProperties.displayName
            }
        }
    } catch {
        Write-Warning "  Could not retrieve members for group: $($group.DisplayName)"
    }
}

$groupsFile = Join-Path $OutputPath "entra-groups_${timestamp}.csv"
$membershipsFile = Join-Path $OutputPath "entra-group-memberships_${timestamp}.csv"
$groupExport | Export-Csv -Path $groupsFile -NoTypeInformation -Encoding UTF8
$membershipExport | Export-Csv -Path $membershipsFile -NoTypeInformation -Encoding UTF8

Write-Host "  Exported $($groupExport.Count) groups with $($membershipExport.Count) memberships." -ForegroundColor Green

# ── Step 4: Export app registrations ───────────────────────────────────────
Write-Host "[4/5] Exporting app registrations..." -ForegroundColor Yellow

$apps = Get-MgApplication -All -Property Id, AppId, DisplayName, SignInAudience, CreatedDateTime, Web, RequiredResourceAccess

$appExport = $apps | ForEach-Object {
    [PSCustomObject]@{
        ObjectId        = $_.Id
        AppId           = $_.AppId
        DisplayName     = $_.DisplayName
        SignInAudience  = $_.SignInAudience
        CreatedDateTime = $_.CreatedDateTime
        ReplyUrls       = ($_.Web.RedirectUris -join "; ")
    }
}

$appsFile = Join-Path $OutputPath "entra-app-registrations_${timestamp}.csv"
$appExport | Export-Csv -Path $appsFile -NoTypeInformation -Encoding UTF8
Write-Host "  Exported $($appExport.Count) app registrations." -ForegroundColor Green

# ── Step 5: Export service principals ──────────────────────────────────────
Write-Host "[5/5] Exporting service principals..." -ForegroundColor Yellow

$servicePrincipals = Get-MgServicePrincipal -All -Property Id, AppId, DisplayName, ServicePrincipalType, AccountEnabled

$spExport = $servicePrincipals | ForEach-Object {
    [PSCustomObject]@{
        ObjectId             = $_.Id
        AppId                = $_.AppId
        DisplayName          = $_.DisplayName
        ServicePrincipalType = $_.ServicePrincipalType
        AccountEnabled       = $_.AccountEnabled
    }
}

$spFile = Join-Path $OutputPath "entra-service-principals_${timestamp}.csv"
$spExport | Export-Csv -Path $spFile -NoTypeInformation -Encoding UTF8
Write-Host "  Exported $($spExport.Count) service principals." -ForegroundColor Green

# ── Disconnect ─────────────────────────────────────────────────────────────
Disconnect-MgGraph | Out-Null

Write-Host ""
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host " Export Complete" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "  Users file              : $usersFile" -ForegroundColor Green
Write-Host "  Groups file             : $groupsFile" -ForegroundColor Green
Write-Host "  Group memberships file  : $membershipsFile" -ForegroundColor Green
Write-Host "  App registrations file  : $appsFile" -ForegroundColor Green
Write-Host "  Service principals file : $spFile" -ForegroundColor Green
Write-Host ""
Write-Host "  Users  — Members: $($memberUsers.Count) | Guests: $($guestUsers.Count)" -ForegroundColor White
Write-Host "  Groups — Total: $($groupExport.Count)" -ForegroundColor White
Write-Host "  Apps   — Total: $($appExport.Count)" -ForegroundColor White
Write-Host ""
Write-Host ">> Use these exports as input for the preparation scripts." -ForegroundColor Yellow
Write-Host ">> Guest users must be re-invited in the target tenant." -ForegroundColor Yellow
