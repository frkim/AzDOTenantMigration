<#
.SYNOPSIS
    Provisions user accounts in the target Entra ID tenant.

.DESCRIPTION
    Reads the user inventory exported from the source tenant and creates
    corresponding user accounts in the target tenant (zava.com). Uses the
    UPN prefix from the source to construct the new UPN in the target domain.

    Supports both creating new cloud users and generating a mapping report.

    Output: CSV file with created user details and mapping.

.PARAMETER SourceUsersFile
    Path to the CSV file exported by 07-Export-EntraIDInventory.ps1 (entra-users_*.csv).

.PARAMETER TargetTenantId
    The tenant ID or domain of the target Entra ID tenant (e.g., "zava.com").

.PARAMETER TargetDomain
    The target domain for new UPNs (e.g., "zava.com").

.PARAMETER WhatIf
    If specified, generates the mapping report without creating accounts.

.PARAMETER OutputPath
    Directory where the export files will be saved. Defaults to ./output.

.PREREQUISITES
    - Microsoft Graph PowerShell SDK (Install-Module Microsoft.Graph)
    - User Administrator role on the target tenant
    - Permissions: User.ReadWrite.All

.EXAMPLE
    # Preview only (no changes)
    .\01-Provision-Users.ps1 -SourceUsersFile "./output/entra-users_20260301.csv" -TargetTenantId "zava.com" -TargetDomain "zava.com" -WhatIf

    # Create users
    .\01-Provision-Users.ps1 -SourceUsersFile "./output/entra-users_20260301.csv" -TargetTenantId "zava.com" -TargetDomain "zava.com"

.NOTES
    Migration Phase : Preparation
    Checklist Item  : #1 - Provision all user accounts in the target tenant
    Author          : Migration Team
    Date            : 2026-03-13
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory = $true)]
    [string]$SourceUsersFile,

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

if (-not (Test-Path $SourceUsersFile)) {
    Write-Error "Source users file not found: $SourceUsersFile"
    return
}

Write-Host "============================================================" -ForegroundColor Cyan
Write-Host " Provision Users in Target Tenant — $TargetDomain" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host ""

# ── Load source users ─────────────────────────────────────────────────────
Write-Host "[1/4] Loading source user inventory..." -ForegroundColor Yellow

$sourceUsers = Import-Csv -Path $SourceUsersFile
$memberUsers = $sourceUsers | Where-Object { $_.UserType -eq "Member" }
$guestUsers = $sourceUsers | Where-Object { $_.UserType -eq "Guest" }

Write-Host "  Total users: $($sourceUsers.Count) (Members: $($memberUsers.Count), Guests: $($guestUsers.Count))" -ForegroundColor Green

# ── Connect to target tenant ──────────────────────────────────────────────
Write-Host "[2/4] Connecting to target tenant..." -ForegroundColor Yellow

Connect-MgGraph -TenantId $TargetTenantId -Scopes "User.ReadWrite.All" -NoWelcome
$context = Get-MgContext
Write-Host "  Connected as: $($context.Account)" -ForegroundColor Green

# ── Get existing users in target tenant ───────────────────────────────────
Write-Host "[3/4] Checking existing users in target tenant..." -ForegroundColor Yellow

$existingUsers = Get-MgUser -All -Property UserPrincipalName | Select-Object -ExpandProperty UserPrincipalName
$existingUpnSet = [System.Collections.Generic.HashSet[string]]::new(
    [System.StringComparer]::OrdinalIgnoreCase
)
$existingUsers | ForEach-Object { $existingUpnSet.Add($_) | Out-Null }

Write-Host "  Existing users in target tenant: $($existingUpnSet.Count)" -ForegroundColor Green

# ── Provision member users ────────────────────────────────────────────────
Write-Host "[4/4] Processing member users..." -ForegroundColor Yellow

$results = @()
$created = 0
$skipped = 0
$failed = 0

foreach ($user in $memberUsers) {
    # Extract UPN prefix and construct target UPN
    $sourceUpn = $user.UserPrincipalName
    $upnPrefix = ($sourceUpn -split "@")[0]
    $targetUpn = "${upnPrefix}@${TargetDomain}"

    $status = "Unknown"

    if ($existingUpnSet.Contains($targetUpn)) {
        $status = "AlreadyExists"
        $skipped++
        Write-Host "  SKIP: $targetUpn (already exists)" -ForegroundColor Gray
    } elseif ($PSCmdlet.ShouldProcess($targetUpn, "Create user")) {
        try {
            # Generate a random temporary password
            $tempPassword = -join ((
                (65..90 | Get-Random -Count 4 | ForEach-Object { [char]$_ }) +
                (97..122 | Get-Random -Count 4 | ForEach-Object { [char]$_ }) +
                (48..57 | Get-Random -Count 2 | ForEach-Object { [char]$_ }) +
                ('!', '@', '#', '$' | Get-Random -Count 2)
            ) | Sort-Object { Get-Random })

            $newUser = New-MgUser `
                -DisplayName $user.DisplayName `
                -UserPrincipalName $targetUpn `
                -MailNickname $upnPrefix `
                -Department $user.Department `
                -JobTitle $user.JobTitle `
                -AccountEnabled $true `
                -PasswordProfile @{
                    ForceChangePasswordNextSignIn = $true
                    Password = $tempPassword
                }

            $status = "Created"
            $created++
            Write-Host "  CREATE: $targetUpn" -ForegroundColor Green
        } catch {
            $status = "Failed: $($_.Exception.Message)"
            $failed++
            Write-Warning "  FAILED: $targetUpn — $($_.Exception.Message)"
        }
    } else {
        $status = "WhatIf"
    }

    $results += [PSCustomObject]@{
        SourceUPN     = $sourceUpn
        TargetUPN     = $targetUpn
        DisplayName   = $user.DisplayName
        UserType      = $user.UserType
        Department    = $user.Department
        Status        = $status
    }
}

# ── Handle guest users (B2B invitations) ──────────────────────────────────
Write-Host ""
Write-Host "  Processing guest users (B2B)..." -ForegroundColor Yellow

foreach ($guest in $guestUsers) {
    $results += [PSCustomObject]@{
        SourceUPN     = $guest.UserPrincipalName
        TargetUPN     = "GUEST — Requires B2B invitation"
        DisplayName   = $guest.DisplayName
        UserType      = "Guest"
        Department    = $guest.Department
        Status        = "RequiresInvitation"
    }
}

# ── Export results ──────────────────────────────────────────────────────────
$resultsFile = Join-Path $OutputPath "user-provisioning-results_${timestamp}.csv"
$results | Export-Csv -Path $resultsFile -NoTypeInformation -Encoding UTF8

Disconnect-MgGraph | Out-Null

Write-Host ""
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host " Provisioning Complete" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "  Created       : $created" -ForegroundColor Green
Write-Host "  Already exist : $skipped" -ForegroundColor Yellow
Write-Host "  Failed        : $failed" -ForegroundColor $(if ($failed -gt 0) { "Red" } else { "Green" })
Write-Host "  Guests (TBD)  : $($guestUsers.Count)" -ForegroundColor Yellow
Write-Host "  Results file  : $resultsFile" -ForegroundColor Green
Write-Host ""
Write-Host ">> Review the results file and resolve any failures before proceeding." -ForegroundColor Yellow
Write-Host ">> Guest users must be invited separately using New-MgInvitation." -ForegroundColor Yellow
