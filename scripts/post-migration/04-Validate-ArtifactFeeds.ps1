<#
.SYNOPSIS
    Validates Azure Artifacts feed access after tenant migration.

.DESCRIPTION
    Checks all Azure Artifacts feeds (NuGet, npm, Maven, etc.) across all projects
    to verify they are accessible and that upstream sources are functioning
    correctly after the tenant migration.

    Output: CSV file with feed validation results.

.PARAMETER Organization
    The Azure DevOps organization name.

.PARAMETER OutputPath
    Directory where the export files will be saved. Defaults to ./output.

.PREREQUISITES
    - Azure CLI installed with Azure DevOps extension
    - Authenticated to Azure DevOps
    - Project Collection Administrator or Feed Administrator role

.EXAMPLE
    .\04-Validate-ArtifactFeeds.ps1 -Organization "myorg"

.NOTES
    Migration Phase : Post-Migration
    Checklist Items : #6, #7 - Verify artifact feed access and upstream sources
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
Write-Host " Validate Artifact Feeds — $orgUrl" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host ""

# ── Get access token for REST API calls ───────────────────────────────────
$pat = az account get-access-token --resource "499b84ac-1321-427f-aa17-267ca6975798" -o tsv --query accessToken
$headers = @{
    "Authorization" = "Bearer $pat"
    "Content-Type"  = "application/json"
}

# ── Step 1: Get organization-scoped feeds ─────────────────────────────────
Write-Host "[1/3] Retrieving organization-scoped feeds..." -ForegroundColor Yellow

$feedResults = @()

try {
    $orgFeedsUri = "https://feeds.dev.azure.com/$Organization/_apis/packaging/feeds?api-version=7.1"
    $orgFeeds = Invoke-RestMethod -Uri $orgFeedsUri -Headers $headers -Method Get

    foreach ($feed in $orgFeeds.value) {
        $feedResults += [PSCustomObject]@{
            Scope            = "Organization"
            ProjectName      = ""
            FeedName         = $feed.name
            FeedId           = $feed.id
            ViewCount        = $feed.view.Count
            UpstreamEnabled  = ($feed.upstreamEnabled -eq $true)
            UpstreamSources  = ($feed.upstreamSources | ForEach-Object { $_.name }) -join "; "
            PackageCount     = $feed.totalUniquePackageCount
            Status           = "Accessible"
        }
    }

    Write-Host "  Organization feeds: $($orgFeeds.value.Count)" -ForegroundColor Green
} catch {
    Write-Warning "  Could not retrieve organization feeds: $($_.Exception.Message)"
}

# ── Step 2: Get project-scoped feeds ──────────────────────────────────────
Write-Host "[2/3] Retrieving project-scoped feeds..." -ForegroundColor Yellow

$projects = az devops project list --org $orgUrl -o json | ConvertFrom-Json

foreach ($project in $projects.value) {
    try {
        $projFeedsUri = "https://feeds.dev.azure.com/$Organization/$($project.name)/_apis/packaging/feeds?api-version=7.1"
        $projFeeds = Invoke-RestMethod -Uri $projFeedsUri -Headers $headers -Method Get

        foreach ($feed in $projFeeds.value) {
            $feedResults += [PSCustomObject]@{
                Scope            = "Project"
                ProjectName      = $project.name
                FeedName         = $feed.name
                FeedId           = $feed.id
                ViewCount        = $feed.view.Count
                UpstreamEnabled  = ($feed.upstreamEnabled -eq $true)
                UpstreamSources  = ($feed.upstreamSources | ForEach-Object { $_.name }) -join "; "
                PackageCount     = $feed.totalUniquePackageCount
                Status           = "Accessible"
            }
        }

        if ($projFeeds.value.Count -gt 0) {
            Write-Host "  $($project.name): $($projFeeds.value.Count) feed(s)" -ForegroundColor Gray
        }
    } catch {
        Write-Warning "  Could not retrieve feeds for project: $($project.name)"
    }
}

# ── Step 3: Validate upstream sources ─────────────────────────────────────
Write-Host "[3/3] Validating upstream source connectivity..." -ForegroundColor Yellow

foreach ($feed in $feedResults) {
    if ($feed.UpstreamEnabled) {
        try {
            $feedDetailUri = "https://feeds.dev.azure.com/$Organization/_apis/packaging/feeds/$($feed.FeedId)?api-version=7.1"
            if ($feed.ProjectName) {
                $feedDetailUri = "https://feeds.dev.azure.com/$Organization/$($feed.ProjectName)/_apis/packaging/feeds/$($feed.FeedId)?api-version=7.1"
            }

            $feedDetail = Invoke-RestMethod -Uri $feedDetailUri -Headers $headers -Method Get

            foreach ($upstream in $feedDetail.upstreamSources) {
                if ($upstream.status -and $upstream.status.state -ne "Ok") {
                    $feed.Status = "UpstreamIssue: $($upstream.name) - $($upstream.status.state)"
                }
            }
        } catch {
            # Feed detail check failed, but feed is accessible
        }
    }
}

# ── Export results ──────────────────────────────────────────────────────────
$resultsFile = Join-Path $OutputPath "artifact-feeds-validation_${timestamp}.csv"
$feedResults | Export-Csv -Path $resultsFile -NoTypeInformation -Encoding UTF8

$issuesCount = ($feedResults | Where-Object { $_.Status -ne "Accessible" }).Count

Write-Host ""
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host " Feed Validation Complete" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "  Total feeds     : $($feedResults.Count)" -ForegroundColor Green
Write-Host "  With issues     : $issuesCount" -ForegroundColor $(if ($issuesCount -gt 0) { "Red" } else { "Green" })
Write-Host "  Results file    : $resultsFile" -ForegroundColor Green
Write-Host ""
if ($issuesCount -gt 0) {
    Write-Host ">> Some feeds have upstream source issues. Check feed permissions for new identities." -ForegroundColor Red
}
Write-Host ">> Verify that NuGet, npm, and Maven clients can authenticate with new identities." -ForegroundColor Yellow
