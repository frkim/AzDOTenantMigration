<#
.SYNOPSIS
    Backs up Azure DevOps organization settings, permissions, and configurations.

.DESCRIPTION
    Performs a comprehensive backup of Azure DevOps organization and project
    configurations before the tenant migration. Exports:
    - Organization settings
    - Project details
    - Team configurations
    - Repository policies
    - Pipeline definitions
    - Variable groups
    - Build/release definitions metadata

    Output: JSON and CSV files organized by project.

.PARAMETER Organization
    The Azure DevOps organization name.

.PARAMETER OutputPath
    Directory where the backup files will be saved. Defaults to ./output/backup.

.PREREQUISITES
    - Azure CLI installed with Azure DevOps extension
    - Authenticated to Azure DevOps
    - Project Collection Administrator role

.EXAMPLE
    .\06-Backup-AzDOSettings.ps1 -Organization "myorg"

.NOTES
    Migration Phase : Preparation
    Checklist Item  : #11 - Back up all Azure DevOps organization settings and permissions
    Author          : Migration Team
    Date            : 2026-03-13
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$Organization,

    [Parameter(Mandatory = $false)]
    [string]$OutputPath = "./output/backup"
)

$ErrorActionPreference = "Stop"
$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
$backupDir = Join-Path $OutputPath $timestamp

if (-not (Test-Path $backupDir)) {
    New-Item -ItemType Directory -Path $backupDir -Force | Out-Null
}

$orgUrl = "https://dev.azure.com/$Organization"

Write-Host "============================================================" -ForegroundColor Cyan
Write-Host " Backup Azure DevOps Settings — $orgUrl" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "  Backup directory: $backupDir" -ForegroundColor White
Write-Host ""

# ── Step 1: List and backup all projects ──────────────────────────────────
Write-Host "[1/5] Backing up project list..." -ForegroundColor Yellow

$projects = az devops project list --org $orgUrl -o json
$projects | Out-File -FilePath (Join-Path $backupDir "projects.json") -Encoding UTF8

$projectList = $projects | ConvertFrom-Json
Write-Host "  Projects: $($projectList.value.Count)" -ForegroundColor Green

# ── Step 2: Backup per-project settings ───────────────────────────────────
Write-Host "[2/5] Backing up per-project configurations..." -ForegroundColor Yellow

foreach ($project in $projectList.value) {
    $projDir = Join-Path $backupDir $project.name
    New-Item -ItemType Directory -Path $projDir -Force | Out-Null

    Write-Host "  Project: $($project.name)..." -ForegroundColor Gray

    # Project details
    try {
        $projDetails = az devops project show --project $project.name --org $orgUrl -o json
        $projDetails | Out-File -FilePath (Join-Path $projDir "project-details.json") -Encoding UTF8
    } catch { Write-Warning "    Could not export project details" }

    # Teams
    try {
        $teams = az devops team list --project $project.name --org $orgUrl -o json
        $teams | Out-File -FilePath (Join-Path $projDir "teams.json") -Encoding UTF8
    } catch { Write-Warning "    Could not export teams" }

    # Repositories
    try {
        $repos = az repos list --project $project.name --org $orgUrl -o json
        $repos | Out-File -FilePath (Join-Path $projDir "repos.json") -Encoding UTF8
    } catch { Write-Warning "    Could not export repos" }

    # Repository policies
    try {
        $policies = az repos policy list --project $project.name --org $orgUrl -o json
        $policies | Out-File -FilePath (Join-Path $projDir "repo-policies.json") -Encoding UTF8
    } catch { Write-Warning "    Could not export repo policies" }

    # Service connections
    try {
        $endpoints = az devops service-endpoint list --project $project.name --org $orgUrl -o json
        $endpoints | Out-File -FilePath (Join-Path $projDir "service-connections.json") -Encoding UTF8
    } catch { Write-Warning "    Could not export service connections" }

    # Pipelines (build definitions)
    try {
        $pipelines = az pipelines list --project $project.name --org $orgUrl -o json
        $pipelines | Out-File -FilePath (Join-Path $projDir "pipelines.json") -Encoding UTF8
    } catch { Write-Warning "    Could not export pipelines" }

    # Variable groups
    try {
        $varGroups = az pipelines variable-group list --project $project.name --org $orgUrl -o json
        $varGroups | Out-File -FilePath (Join-Path $projDir "variable-groups.json") -Encoding UTF8
    } catch { Write-Warning "    Could not export variable groups" }

    # Environments
    try {
        $envs = az devops invoke `
            --area distributedtask `
            --resource environments `
            --org $orgUrl `
            --route-parameters project=$($project.name) `
            --api-version 7.1 `
            -o json
        $envs | Out-File -FilePath (Join-Path $projDir "environments.json") -Encoding UTF8
    } catch { Write-Warning "    Could not export environments" }
}

# ── Step 3: Backup organization-level security groups ─────────────────────
Write-Host "[3/5] Backing up organization-level security groups..." -ForegroundColor Yellow

try {
    $orgGroups = az devops security group list --org $orgUrl --scope organization -o json
    $orgGroups | Out-File -FilePath (Join-Path $backupDir "org-security-groups.json") -Encoding UTF8
    Write-Host "  Organization security groups exported." -ForegroundColor Green
} catch { Write-Warning "  Could not export organization security groups" }

# ── Step 4: Backup extensions ─────────────────────────────────────────────
Write-Host "[4/5] Backing up installed extensions..." -ForegroundColor Yellow

try {
    $extensions = az devops extension list --org $orgUrl -o json
    $extensions | Out-File -FilePath (Join-Path $backupDir "extensions.json") -Encoding UTF8
    Write-Host "  Extensions exported." -ForegroundColor Green
} catch { Write-Warning "  Could not export extensions" }

# ── Step 5: Backup agent pools ────────────────────────────────────────────
Write-Host "[5/5] Backing up agent pools..." -ForegroundColor Yellow

try {
    $pools = az devops invoke `
        --area distributedtask `
        --resource pools `
        --org $orgUrl `
        --api-version 7.1 `
        -o json
    $pools | Out-File -FilePath (Join-Path $backupDir "agent-pools.json") -Encoding UTF8
    Write-Host "  Agent pools exported." -ForegroundColor Green
} catch { Write-Warning "  Could not export agent pools" }

# ── Summary ───────────────────────────────────────────────────────────────
$fileCount = (Get-ChildItem -Path $backupDir -Recurse -File).Count
$dirSize = (Get-ChildItem -Path $backupDir -Recurse -File | Measure-Object -Property Length -Sum).Sum / 1KB

Write-Host ""
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host " Backup Complete" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "  Backup directory  : $backupDir" -ForegroundColor Green
Write-Host "  Total files       : $fileCount" -ForegroundColor Green
Write-Host "  Total size        : $([math]::Round($dirSize, 2)) KB" -ForegroundColor Green
Write-Host ""
Write-Host ">> Store this backup securely. It can be used for reference during post-migration validation." -ForegroundColor Yellow
