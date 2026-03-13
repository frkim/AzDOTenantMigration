# Migration Scripts

PowerShell automation scripts for the Azure DevOps tenant migration from **contoso.com** to **zava.com**.

## Prerequisites

| Tool | Installation |
|---|---|
| **Azure CLI** | [Install Azure CLI](https://learn.microsoft.com/en-us/cli/azure/install-azure-cli) |
| **Azure DevOps CLI extension** | `az extension add --name azure-devops` |
| **Microsoft Graph PowerShell SDK** | `Install-Module Microsoft.Graph -Scope CurrentUser` |
| **PowerShell 7+** | [Install PowerShell](https://learn.microsoft.com/en-us/powershell/scripting/install/installing-powershell) |

## Authentication

Before running any script, authenticate to the required services:

```powershell
# Azure CLI — sign in to Azure and Azure DevOps
az login
az devops configure --defaults organization=https://dev.azure.com/{org}

# Microsoft Graph — sign in with required scopes (prompted per script)
Connect-MgGraph -Scopes "User.Read.All"
```

## Script Organization

All scripts output results to `./output/` by default (configurable via `-OutputPath`).

---

### Phase 1 — Pre-Migration (`pre-migration/`)

Inventory and assessment scripts. Run these 2-4 weeks before migration.

| # | Script | Purpose | Checklist Item |
|---|---|---|---|
| 1 | [01-Export-OrgAdmins.ps1](pre-migration/01-Export-OrgAdmins.ps1) | Export Organization Owner and Project Collection Administrators | #1 |
| 2 | [02-Export-Users.ps1](pre-migration/02-Export-Users.ps1) | Export all AzDO users with access levels and licenses | #3 |
| 3 | [03-Export-Groups.ps1](pre-migration/03-Export-Groups.ps1) | Export all AzDO groups and memberships (including Entra ID groups) | #4 |
| 4 | [04-Export-ServiceConnections.ps1](pre-migration/04-Export-ServiceConnections.ps1) | Export all service connections across all projects | #5 |
| 5 | [05-Export-Extensions.ps1](pre-migration/05-Export-Extensions.ps1) | Export all installed marketplace extensions | #6 |
| 6 | [06-Export-AgentPools.ps1](pre-migration/06-Export-AgentPools.ps1) | Export all agent pools and agent registrations | #8 |
| 7 | [07-Export-EntraIDInventory.ps1](pre-migration/07-Export-EntraIDInventory.ps1) | Export Entra ID users, groups, app registrations from source tenant | #3, #4, #10 |
| 8 | [08-Export-RBACAssignments.ps1](pre-migration/08-Export-RBACAssignments.ps1) | Export Azure RBAC role assignments for service principals | #10 |

**Recommended execution order:**

```powershell
# Azure DevOps inventory
.\pre-migration\01-Export-OrgAdmins.ps1 -Organization "myorg"
.\pre-migration\02-Export-Users.ps1 -Organization "myorg"
.\pre-migration\03-Export-Groups.ps1 -Organization "myorg"
.\pre-migration\04-Export-ServiceConnections.ps1 -Organization "myorg"
.\pre-migration\05-Export-Extensions.ps1 -Organization "myorg"
.\pre-migration\06-Export-AgentPools.ps1 -Organization "myorg"

# Entra ID and Azure inventory
.\pre-migration\07-Export-EntraIDInventory.ps1 -SourceTenantId "contoso.com"
.\pre-migration\08-Export-RBACAssignments.ps1
```

---

### Phase 2 — Preparation (`preparation/`)

Provisioning and setup scripts. Run these 1-2 weeks before migration.

| # | Script | Purpose | Checklist Item |
|---|---|---|---|
| 1 | [01-Provision-Users.ps1](preparation/01-Provision-Users.ps1) | Create user accounts in the target tenant | #1 |
| 2 | [02-Verify-UPNMapping.ps1](preparation/02-Verify-UPNMapping.ps1) | Verify UPN mapping between source and target users | #2 |
| 3 | [03-Create-Groups.ps1](preparation/03-Create-Groups.ps1) | Recreate Entra ID groups and populate memberships | #3, #4, #5 |
| 4 | [04-Create-AppRegistrations.ps1](preparation/04-Create-AppRegistrations.ps1) | Create app registrations, service principals, and secrets | #6, #7 |
| 5 | [05-Assign-RBACRoles.ps1](preparation/05-Assign-RBACRoles.ps1) | Assign Azure RBAC roles to new service principals | #8 |
| 6 | [06-Backup-AzDOSettings.ps1](preparation/06-Backup-AzDOSettings.ps1) | Backup all Azure DevOps configurations and permissions | #11 |

**Recommended execution order:**

```powershell
# Provision identities (use -WhatIf first!)
.\preparation\01-Provision-Users.ps1 -SourceUsersFile "./output/entra-users_*.csv" -TargetTenantId "zava.com" -TargetDomain "zava.com" -WhatIf
.\preparation\01-Provision-Users.ps1 -SourceUsersFile "./output/entra-users_*.csv" -TargetTenantId "zava.com" -TargetDomain "zava.com"

# Verify mapping
.\preparation\02-Verify-UPNMapping.ps1 -SourceUsersFile "./output/entra-users_*.csv" -TargetTenantId "zava.com" -TargetDomain "zava.com"

# Create groups
.\preparation\03-Create-Groups.ps1 -SourceGroupsFile "./output/entra-groups_*.csv" -SourceMembershipsFile "./output/entra-group-memberships_*.csv" -TargetTenantId "zava.com" -TargetDomain "zava.com"

# Create app registrations and assign RBAC
.\preparation\04-Create-AppRegistrations.ps1 -SourceAppsFile "./output/entra-app-registrations_*.csv" -TargetTenantId "zava.com"
.\preparation\05-Assign-RBACRoles.ps1 -SourceRBACFile "./output/rbac-assignments_*.csv" -AppCredentialsFile "./output/app-credentials_*.csv"

# Backup before migration day
.\preparation\06-Backup-AzDOSettings.ps1 -Organization "myorg"
```

---

### Phase 3 — Post-Migration (`post-migration/`)

Validation and reconfiguration scripts. Run these immediately after and up to 2 weeks following the migration.

| # | Script | Purpose | Checklist Item |
|---|---|---|---|
| 1 | [01-Verify-UserAccess.ps1](post-migration/01-Verify-UserAccess.ps1) | Verify user access, access levels, and group memberships | #1, #2, #3 |
| 2 | [02-Update-ServiceConnections.ps1](post-migration/02-Update-ServiceConnections.ps1) | Update service connections with new service principals | #4 |
| 3 | [03-Validate-Pipelines.ps1](post-migration/03-Validate-Pipelines.ps1) | Validate CI/CD pipeline execution | #5 |
| 4 | [04-Validate-ArtifactFeeds.ps1](post-migration/04-Validate-ArtifactFeeds.ps1) | Validate artifact feed access and upstream sources | #6, #7 |

**Recommended execution order:**

```powershell
# Verify access (compare with pre-migration export)
.\post-migration\01-Verify-UserAccess.ps1 -Organization "myorg" -PreMigrationUsersFile "./output/azdo-users_*.csv"

# Update service connections
.\post-migration\02-Update-ServiceConnections.ps1 -Organization "myorg" -ServiceConnectionsFile "./output/service-connections-azure_*.csv" -AppCredentialsFile "./output/app-credentials_*.csv" -TargetTenantId "your-target-tenant-id"

# Validate pipelines
.\post-migration\03-Validate-Pipelines.ps1 -Organization "myorg"
.\post-migration\03-Validate-Pipelines.ps1 -Organization "myorg" -TriggerRuns  # Trigger actual runs

# Validate artifact feeds
.\post-migration\04-Validate-ArtifactFeeds.ps1 -Organization "myorg"
```

---

### Phase 4 — Cleanup (`cleanup/`)

Cleanup scripts. Run these 2-4 weeks after migration is fully validated.

| # | Script | Purpose | Checklist Item |
|---|---|---|---|
| 1 | [01-Cleanup-SourceTenant.ps1](cleanup/01-Cleanup-SourceTenant.ps1) | Identify and remove temporary accounts and old app registrations | #1, #2 |

**Usage:**

```powershell
# Dry run first (always!)
.\cleanup\01-Cleanup-SourceTenant.ps1 -SourceTenantId "contoso.com" -MigrationTag "migration-temp"

# Execute cleanup (requires confirmation)
.\cleanup\01-Cleanup-SourceTenant.ps1 -SourceTenantId "contoso.com" -MigrationTag "migration-temp" -Execute
```

---

## Output Files

All scripts export results to timestamped CSV files in the output directory:

| File Pattern | Source Script | Description |
|---|---|---|
| `org-admins_*.csv` | Pre-01 | Organization admins |
| `azdo-users_*.csv` | Pre-02 | AzDO users and access levels |
| `azdo-groups_*.csv` | Pre-03 | AzDO groups |
| `azdo-group-memberships_*.csv` | Pre-03 | AzDO group memberships |
| `service-connections_*.csv` | Pre-04 | All service connections |
| `extensions_*.csv` | Pre-05 | Installed extensions |
| `agent-pools_*.csv` | Pre-06 | Agent pools |
| `entra-users_*.csv` | Pre-07 | Entra ID users |
| `entra-groups_*.csv` | Pre-07 | Entra ID groups |
| `entra-group-memberships_*.csv` | Pre-07 | Entra ID group memberships |
| `entra-app-registrations_*.csv` | Pre-07 | App registrations |
| `rbac-assignments_*.csv` | Pre-08 | RBAC role assignments |
| `user-provisioning-results_*.csv` | Prep-01 | User provisioning results |
| `upn-mapping-verification_*.csv` | Prep-02 | UPN mapping report |
| `group-creation-results_*.csv` | Prep-03 | Group creation results |
| `app-credentials_*.csv` | Prep-04 | App credentials (**SECURE THIS FILE**) |
| `rbac-assignment-results_*.csv` | Prep-05 | RBAC assignment results |
| `backup/*` | Prep-06 | Full AzDO settings backup |
| `user-access-verification_*.csv` | Post-01 | User access verification |
| `service-connection-update-results_*.csv` | Post-02 | Service connection updates |
| `pipeline-validation_*.csv` | Post-03 | Pipeline validation |
| `artifact-feeds-validation_*.csv` | Post-04 | Artifact feed validation |
| `cleanup-report_*.csv` | Cleanup-01 | Cleanup candidates |

## Security Notes

- **Credentials file** (`app-credentials_*.csv`) contains client secrets. Store securely and delete after migration.
- All scripts support `-WhatIf` where applicable. Always perform a dry run first.
- Review all CSV outputs before executing destructive operations.
- Use the `-OutputPath` parameter to direct exports to a secure location.
