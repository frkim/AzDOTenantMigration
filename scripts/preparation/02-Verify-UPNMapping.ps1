<#
.SYNOPSIS
    Verifies UPN mapping between source and target tenant users.

.DESCRIPTION
    Compares users from the source tenant export against users in the target
    tenant to verify that UPN mapping will succeed during the Azure DevOps
    directory switch. Identifies matched, unmatched, and ambiguous mappings.

    Output: CSV file with mapping status for each user.

.PARAMETER SourceUsersFile
    Path to the CSV file exported by 07-Export-EntraIDInventory.ps1 (entra-users_*.csv).

.PARAMETER TargetTenantId
    The tenant ID or domain of the target Entra ID tenant (e.g., "zava.com").

.PARAMETER TargetDomain
    The target domain for UPN matching (e.g., "zava.com").

.PARAMETER OutputPath
    Directory where the export files will be saved. Defaults to ./output.

.PREREQUISITES
    - Microsoft Graph PowerShell SDK
    - User.Read.All permission on the target tenant

.EXAMPLE
    .\02-Verify-UPNMapping.ps1 -SourceUsersFile "./output/entra-users_20260301.csv" -TargetTenantId "zava.com" -TargetDomain "zava.com"

.NOTES
    Migration Phase : Preparation
    Checklist Item  : #2 - Verify UPN mapping between source and target users
    Author          : Migration Team
    Date            : 2026-03-13
#>

[CmdletBinding()]
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

Write-Host "============================================================" -ForegroundColor Cyan
Write-Host " Verify UPN Mapping — Source → $TargetDomain" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host ""

# ── Load source users ─────────────────────────────────────────────────────
Write-Host "[1/3] Loading source user inventory..." -ForegroundColor Yellow

$sourceUsers = Import-Csv -Path $SourceUsersFile
Write-Host "  Source users: $($sourceUsers.Count)" -ForegroundColor Green

# ── Load target tenant users ──────────────────────────────────────────────
Write-Host "[2/3] Connecting to target tenant and loading users..." -ForegroundColor Yellow

Connect-MgGraph -TenantId $TargetTenantId -Scopes "User.Read.All" -NoWelcome

$targetUsers = Get-MgUser -All -Property Id, UserPrincipalName, DisplayName, Mail
Write-Host "  Target users: $($targetUsers.Count)" -ForegroundColor Green

# Build lookup dictionaries for matching
$targetByUpnPrefix = @{}
$targetByMail = @{}
$targetByDisplayName = @{}

foreach ($tu in $targetUsers) {
    $prefix = ($tu.UserPrincipalName -split "@")[0].ToLower()
    $targetByUpnPrefix[$prefix] = $tu

    if ($tu.Mail) {
        $targetByMail[$tu.Mail.ToLower()] = $tu
    }

    $dn = $tu.DisplayName.ToLower()
    if (-not $targetByDisplayName.ContainsKey($dn)) {
        $targetByDisplayName[$dn] = @()
    }
    $targetByDisplayName[$dn] += $tu
}

# ── Perform matching ──────────────────────────────────────────────────────
Write-Host "[3/3] Performing UPN matching analysis..." -ForegroundColor Yellow

$mappingResults = @()
$matched = 0
$unmatched = 0
$mailMatch = 0
$displayMatch = 0

foreach ($user in $sourceUsers) {
    $sourceUpn = $user.UserPrincipalName
    $upnPrefix = ($sourceUpn -split "@")[0].ToLower()
    $expectedTargetUpn = "${upnPrefix}@${TargetDomain}"

    $matchStatus = "Unmatched"
    $matchedTargetUpn = ""
    $matchMethod = ""

    # Priority 1: UPN prefix match
    if ($targetByUpnPrefix.ContainsKey($upnPrefix)) {
        $matchStatus = "Matched"
        $matchedTargetUpn = $targetByUpnPrefix[$upnPrefix].UserPrincipalName
        $matchMethod = "UPN Prefix"
        $matched++
    }
    # Priority 2: Email match
    elseif ($user.Mail -and $targetByMail.ContainsKey($user.Mail.ToLower())) {
        $matchStatus = "Matched (Email)"
        $matchedTargetUpn = $targetByMail[$user.Mail.ToLower()].UserPrincipalName
        $matchMethod = "Email"
        $mailMatch++
    }
    # Priority 3: Display name match (less reliable)
    elseif ($user.DisplayName -and $targetByDisplayName.ContainsKey($user.DisplayName.ToLower())) {
        $candidates = $targetByDisplayName[$user.DisplayName.ToLower()]
        if ($candidates.Count -eq 1) {
            $matchStatus = "Matched (DisplayName)"
            $matchedTargetUpn = $candidates[0].UserPrincipalName
            $matchMethod = "Display Name"
            $displayMatch++
        } else {
            $matchStatus = "Ambiguous (Multiple DisplayName matches)"
            $matchedTargetUpn = ($candidates | ForEach-Object { $_.UserPrincipalName }) -join "; "
            $matchMethod = "Ambiguous"
            $unmatched++
        }
    }
    else {
        $unmatched++
    }

    $mappingResults += [PSCustomObject]@{
        SourceUPN         = $sourceUpn
        DisplayName       = $user.DisplayName
        UserType          = $user.UserType
        ExpectedTargetUPN = $expectedTargetUpn
        MatchedTargetUPN  = $matchedTargetUpn
        MatchStatus       = $matchStatus
        MatchMethod       = $matchMethod
    }
}

# ── Export results ──────────────────────────────────────────────────────────
$mappingFile = Join-Path $OutputPath "upn-mapping-verification_${timestamp}.csv"
$mappingResults | Export-Csv -Path $mappingFile -NoTypeInformation -Encoding UTF8

# Export unmatched for easy review
$unmatchedFile = Join-Path $OutputPath "upn-mapping-unmatched_${timestamp}.csv"
$mappingResults | Where-Object { $_.MatchStatus -notlike "Matched*" -or $_.MatchStatus -like "*Ambiguous*" } |
    Export-Csv -Path $unmatchedFile -NoTypeInformation -Encoding UTF8

Disconnect-MgGraph | Out-Null

$totalMatched = $matched + $mailMatch + $displayMatch

Write-Host ""
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host " Mapping Verification Complete" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "  Total source users      : $($sourceUsers.Count)" -ForegroundColor White
Write-Host "  Matched (UPN)           : $matched" -ForegroundColor Green
Write-Host "  Matched (Email)         : $mailMatch" -ForegroundColor Yellow
Write-Host "  Matched (Display Name)  : $displayMatch" -ForegroundColor Yellow
Write-Host "  Unmatched / Ambiguous   : $unmatched" -ForegroundColor $(if ($unmatched -gt 0) { "Red" } else { "Green" })
Write-Host ""
Write-Host "  Full mapping file       : $mappingFile" -ForegroundColor Green
Write-Host "  Unmatched users file    : $unmatchedFile" -ForegroundColor Green
Write-Host ""
if ($unmatched -gt 0) {
    Write-Host ">> ACTION REQUIRED: $unmatched users have no match in the target tenant." -ForegroundColor Red
    Write-Host ">> These users will LOSE ACCESS after the directory switch." -ForegroundColor Red
    Write-Host ">> Create their accounts in the target tenant or plan manual mapping." -ForegroundColor Red
} else {
    Write-Host ">> All users have a match in the target tenant. Ready to proceed." -ForegroundColor Green
}
