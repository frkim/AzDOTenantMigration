<#
.SYNOPSIS
    Validates CI/CD pipelines after tenant migration.

.DESCRIPTION
    Triggers validation runs for pipelines across all projects to verify they
    can authenticate and execute successfully after the tenant migration.
    Reports pipeline run statuses and identifies failures.

    Output: CSV file with pipeline validation results.

.PARAMETER Organization
    The Azure DevOps organization name.

.PARAMETER ProjectFilter
    Optional. Comma-separated project names to scope validation. If omitted, all projects are checked.

.PARAMETER TriggerRuns
    If specified, triggers actual pipeline runs for validation. Otherwise, only checks pipeline definitions and recent run status.

.PARAMETER OutputPath
    Directory where the export files will be saved. Defaults to ./output.

.PREREQUISITES
    - Azure CLI installed with Azure DevOps extension
    - Authenticated to Azure DevOps
    - Build Administrator or Project Collection Administrator role

.EXAMPLE
    # Check pipeline status without triggering runs
    .\03-Validate-Pipelines.ps1 -Organization "myorg"

    # Trigger validation runs
    .\03-Validate-Pipelines.ps1 -Organization "myorg" -TriggerRuns

.NOTES
    Migration Phase : Post-Migration
    Checklist Item  : #5 - Validate all CI/CD pipelines run successfully
    Author          : Migration Team
    Date            : 2026-03-13
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$Organization,

    [Parameter(Mandatory = $false)]
    [string[]]$ProjectFilter,

    [Parameter(Mandatory = $false)]
    [switch]$TriggerRuns,

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
Write-Host " Validate CI/CD Pipelines — $orgUrl" -ForegroundColor Cyan
Write-Host " Mode: $(if ($TriggerRuns) { 'TRIGGER RUNS' } else { 'CHECK STATUS ONLY' })" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host ""

# ── Get projects ──────────────────────────────────────────────────────────
Write-Host "[1/3] Retrieving projects..." -ForegroundColor Yellow

$projects = az devops project list --org $orgUrl -o json | ConvertFrom-Json

if ($ProjectFilter) {
    $projects.value = $projects.value | Where-Object { $_.name -in $ProjectFilter }
}

Write-Host "  Projects to validate: $($projects.value.Count)" -ForegroundColor Green

# ── Check pipelines ──────────────────────────────────────────────────────
Write-Host "[2/3] Checking pipelines..." -ForegroundColor Yellow

$pipelineResults = @()
$totalPipelines = 0
$successPipelines = 0
$failedPipelines = 0

foreach ($project in $projects.value) {
    Write-Host "  Project: $($project.name)..." -ForegroundColor Gray

    try {
        $pipelines = az pipelines list --org $orgUrl --project $project.name -o json | ConvertFrom-Json

        foreach ($pipeline in $pipelines) {
            $totalPipelines++

            # Get most recent run
            try {
                $runs = az pipelines runs list `
                    --org $orgUrl `
                    --project $project.name `
                    --pipeline-ids $pipeline.id `
                    --top 1 `
                    -o json | ConvertFrom-Json

                $lastRun = $runs | Select-Object -First 1
                $lastRunStatus = if ($lastRun) { $lastRun.result } else { "NoRuns" }
                $lastRunDate = if ($lastRun) { $lastRun.finishTime } else { "" }

                if ($lastRunStatus -eq "succeeded") { $successPipelines++ }
                elseif ($lastRunStatus -eq "failed") { $failedPipelines++ }

            } catch {
                $lastRunStatus = "ErrorCheckingRuns"
                $lastRunDate = ""
            }

            # Optionally trigger a new run
            $triggerResult = ""
            if ($TriggerRuns) {
                try {
                    $newRun = az pipelines run `
                        --org $orgUrl `
                        --project $project.name `
                        --id $pipeline.id `
                        -o json | ConvertFrom-Json

                    $triggerResult = "Triggered (Run ID: $($newRun.id))"
                    Write-Host "    Triggered: $($pipeline.name) (Run $($newRun.id))" -ForegroundColor Cyan
                } catch {
                    $triggerResult = "TriggerFailed: $($_.Exception.Message)"
                    Write-Warning "    Could not trigger: $($pipeline.name)"
                }
            }

            $pipelineResults += [PSCustomObject]@{
                ProjectName    = $project.name
                PipelineName   = $pipeline.name
                PipelineId     = $pipeline.id
                PipelinePath   = $pipeline.path
                LastRunResult  = $lastRunStatus
                LastRunDate    = $lastRunDate
                ValidationRun  = $triggerResult
            }
        }

        Write-Host "    Pipelines: $($pipelines.Count)" -ForegroundColor Gray
    } catch {
        Write-Warning "    Could not retrieve pipelines for: $($project.name)"
    }
}

# ── Step 3: Export results ────────────────────────────────────────────────
Write-Host "[3/3] Exporting results..." -ForegroundColor Yellow

$resultsFile = Join-Path $OutputPath "pipeline-validation_${timestamp}.csv"
$pipelineResults | Export-Csv -Path $resultsFile -NoTypeInformation -Encoding UTF8

# Export failed pipelines separately
$failedFile = Join-Path $OutputPath "pipeline-validation-failed_${timestamp}.csv"
$pipelineResults | Where-Object { $_.LastRunResult -eq "failed" -or $_.LastRunResult -like "Error*" } |
    Export-Csv -Path $failedFile -NoTypeInformation -Encoding UTF8

Write-Host ""
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host " Pipeline Validation Complete" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "  Total pipelines      : $totalPipelines" -ForegroundColor White
Write-Host "  Last run succeeded   : $successPipelines" -ForegroundColor Green
Write-Host "  Last run failed      : $failedPipelines" -ForegroundColor $(if ($failedPipelines -gt 0) { "Red" } else { "Green" })
Write-Host "  Results file         : $resultsFile" -ForegroundColor Green
Write-Host "  Failed pipelines     : $failedFile" -ForegroundColor Green
Write-Host ""
if ($failedPipelines -gt 0) {
    Write-Host ">> $failedPipelines pipelines had failed runs. Investigate service connection or auth issues." -ForegroundColor Red
}
if (-not $TriggerRuns) {
    Write-Host ">> Run with -TriggerRuns to trigger validation pipeline runs." -ForegroundColor Yellow
}
