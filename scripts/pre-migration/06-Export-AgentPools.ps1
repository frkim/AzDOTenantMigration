<#
.SYNOPSIS
    Exports all pipeline agent pools and agent registrations.

.DESCRIPTION
    Inventories all agent pools in the Azure DevOps organization, including
    self-hosted and Microsoft-hosted pools, their agents, and agent status.
    Agent registrations may need reconfiguration after the tenant migration
    if they authenticate using Entra ID identities.

    Output: CSV files with agent pool and agent details.

.PARAMETER Organization
    The Azure DevOps organization name.

.PARAMETER OutputPath
    Directory where the export files will be saved. Defaults to ./output.

.PREREQUISITES
    - Azure CLI installed with Azure DevOps extension
    - Authenticated to Azure DevOps
    - Project Collection Administrator role

.EXAMPLE
    .\06-Export-AgentPools.ps1 -Organization "myorg"

.NOTES
    Migration Phase : Pre-Migration
    Checklist Item  : #8 - Inventory all pipeline agent pools and agent registrations
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
Write-Host " Export Agent Pools — $orgUrl" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host ""

# ── Retrieve agent pools via REST API ──────────────────────────────────────
Write-Host "[1/2] Retrieving agent pools..." -ForegroundColor Yellow

# Use REST API for agent pool details (more comprehensive than CLI)
$poolsResponse = az devops invoke `
    --area distributedtask `
    --resource pools `
    --org $orgUrl `
    --api-version 7.1 `
    -o json | ConvertFrom-Json

$poolExport = @()
$agentExport = @()

foreach ($pool in $poolsResponse.value) {
    $poolExport += [PSCustomObject]@{
        PoolId     = $pool.id
        PoolName   = $pool.name
        PoolType   = $pool.poolType
        IsHosted   = $pool.isHosted
        Size       = $pool.size
        IsLegacy   = $pool.isLegacy
        CreatedOn  = $pool.createdOn
        AutoUpdate = $pool.autoUpdate
    }

    # Get agents in each non-hosted pool
    if (-not $pool.isHosted) {
        Write-Host "  Pool: $($pool.name) (self-hosted, $($pool.size) agents)..." -ForegroundColor Gray

        try {
            $agentsResponse = az devops invoke `
                --area distributedtask `
                --resource agents `
                --org $orgUrl `
                --route-parameters poolId=$($pool.id) `
                --api-version 7.1 `
                -o json | ConvertFrom-Json

            foreach ($agent in $agentsResponse.value) {
                $agentExport += [PSCustomObject]@{
                    PoolName      = $pool.name
                    PoolId        = $pool.id
                    AgentName     = $agent.name
                    AgentId       = $agent.id
                    AgentVersion  = $agent.version
                    Status        = $agent.status
                    Enabled       = $agent.enabled
                    OSDescription = $agent.osDescription
                    CreatedOn     = $agent.createdOn
                }
            }
        } catch {
            Write-Warning "    Could not retrieve agents for pool: $($pool.name)"
        }
    } else {
        Write-Host "  Pool: $($pool.name) (Microsoft-hosted)..." -ForegroundColor Gray
    }
}

# ── Export results ──────────────────────────────────────────────────────────
Write-Host "[2/2] Exporting results..." -ForegroundColor Yellow

$poolsFile = Join-Path $OutputPath "agent-pools_${timestamp}.csv"
$agentsFile = Join-Path $OutputPath "agent-pool-agents_${timestamp}.csv"

$poolExport | Export-Csv -Path $poolsFile -NoTypeInformation -Encoding UTF8
$agentExport | Export-Csv -Path $agentsFile -NoTypeInformation -Encoding UTF8

Write-Host ""
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host " Export Complete" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "  Total agent pools    : $($poolExport.Count)" -ForegroundColor Green
Write-Host "  Self-hosted agents   : $($agentExport.Count)" -ForegroundColor Green
Write-Host "  Pools file           : $poolsFile" -ForegroundColor Green
Write-Host "  Agents file          : $agentsFile" -ForegroundColor Green
Write-Host ""
Write-Host ">> Self-hosted agents using PATs will need token regeneration after migration." -ForegroundColor Yellow
Write-Host ">> Agents using service accounts from contoso.com may need reconfiguration." -ForegroundColor Yellow
