# Azure DevOps Tenant Migration

Migrate the backing directory of an Azure DevOps Services organization from the **contoso.com** Microsoft Entra ID tenant to the **zava.com** tenant — with a comprehensive plan, numbered checklist, Gantt timeline, and ready-to-run PowerShell automation scripts.

## Repository Structure

```
├── AzDO-Migration-Plan.md          # Full migration plan & numbered checklist with Gantt
├── scripts/
│   ├── README.md                   # Script documentation & execution guide
│   ├── pre-migration/              # Phase 1 — Inventory & discovery (8 scripts)
│   │   ├── 01-Export-OrgAdmins.ps1
│   │   ├── 02-Export-Users.ps1
│   │   ├── 03-Export-Groups.ps1
│   │   ├── 04-Export-ServiceConnections.ps1
│   │   ├── 05-Export-Extensions.ps1
│   │   ├── 06-Export-AgentPools.ps1
│   │   ├── 07-Export-EntraIDInventory.ps1
│   │   └── 08-Export-RBACAssignments.ps1
│   ├── preparation/                # Phase 2 — Target tenant setup (6 scripts)
│   │   ├── 01-Provision-Users.ps1
│   │   ├── 02-Verify-UPNMapping.ps1
│   │   ├── 03-Create-Groups.ps1
│   │   ├── 04-Create-AppRegistrations.ps1
│   │   ├── 05-Assign-RBACRoles.ps1
│   │   └── 06-Backup-AzDOSettings.ps1
│   ├── post-migration/             # Phase 4 — Validation & repair (4 scripts)
│   │   ├── 01-Verify-UserAccess.ps1
│   │   ├── 02-Update-ServiceConnections.ps1
│   │   ├── 03-Validate-Pipelines.ps1
│   │   └── 04-Validate-ArtifactFeeds.ps1
│   └── cleanup/                    # Phase 5 — Decommission (1 script)
│       └── 01-Cleanup-SourceTenant.ps1
└── README.md                       # This file
```

## Migration Plan

See [AzDO-Migration-Plan.md](AzDO-Migration-Plan.md) for the full plan (v3.0), including:

| Section | Topic |
|---------|-------|
| 1 | Executive Summary |
| 2 | Scope and Objectives |
| 3 | Prerequisites and Third-Party Dependencies |
| 4 | Users and Groups Migration in Microsoft Entra ID |
| 5 | Managed Identities and Workload Identity Federation |
| 6 | Azure Subscription Transfer Process |
| 7 | Migration Plan — Prioritized Steps |
| 8 | RACI Matrix |
| 9 | Go/No-Go Decision Gates |
| 10 | Detailed Migration Steps |
| 11 | Leveraging AI Tools (GitHub Copilot) for Automation |
| 12 | **Migration Checklist** — 80+ numbered items with script links & Gantt timeline |
| 13 | Rollback Plan |
| 14 | Audit, Compliance, and Governance |
| 15 | Microsoft Official References |

## Automation Scripts

19 PowerShell scripts automate the repeatable parts of the migration. See [scripts/README.md](scripts/README.md) for prerequisites, execution order, and output file reference.

### Prerequisites

- **PowerShell 7+**
- **Azure CLI** with the `azure-devops` extension
- **Microsoft Graph PowerShell SDK** (`Microsoft.Graph.Users`, `Microsoft.Graph.Groups`, `Microsoft.Graph.Applications`)
- Appropriate permissions in both the source and target Entra ID tenants

### Quick Start

```powershell
# 1. Authenticate
az login --tenant contoso.com
az devops configure --defaults organization=https://dev.azure.com/YOUR_ORG

# 2. Run pre-migration inventory
./scripts/pre-migration/01-Export-OrgAdmins.ps1 -Organization "YOUR_ORG"
./scripts/pre-migration/02-Export-Users.ps1      -Organization "YOUR_ORG"
# ... continue with remaining scripts in order
```

> **Tip:** Each script supports `-OutputPath` to control where CSV exports are saved and includes full comment-based help — run `Get-Help ./scripts/pre-migration/01-Export-OrgAdmins.ps1 -Full` for details.

## License

See [LICENSE](LICENSE).
