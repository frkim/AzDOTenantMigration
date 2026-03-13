# Azure DevOps Tenant Migration Plan

## Migrating Azure DevOps (Services) Directory from contoso.com to zava.com

---

## Table of Contents

1. [Executive Summary](#1-executive-summary)
2. [Scope and Objectives](#2-scope-and-objectives)
3. [Prerequisites and Third-Party Dependencies](#3-prerequisites-and-third-party-dependencies)
4. [Users and Groups Migration in Microsoft Entra ID](#4-users-and-groups-migration-in-microsoft-entra-id)
5. [Migration Plan — Prioritized Steps](#5-migration-plan--prioritized-steps)
6. [Detailed Migration Steps](#6-detailed-migration-steps)
7. [Leveraging AI Tools (GitHub Copilot) for Migration Automation](#7-leveraging-ai-tools-github-copilot-for-migration-automation)
8. [Migration Checklist](#8-migration-checklist)
9. [Rollback Plan](#9-rollback-plan)
10. [Microsoft Official References](#10-microsoft-official-references)

---

## 1. Executive Summary

This document provides a comprehensive plan for migrating the Azure DevOps Services organization directory from the **contoso.com** Microsoft Entra ID (formerly Azure Active Directory) tenant to the **zava.com** tenant.

Changing the backing directory of an Azure DevOps organization is a significant operation that impacts user identities, permissions, group memberships, service connections, and integrations. Careful planning, stakeholder alignment, and thorough testing are essential to minimize downtime and disruption.

---

## 2. Scope and Objectives

### In Scope

- Migration of the Azure DevOps Services organization directory connection from **contoso.com** to **zava.com** Entra ID tenant.
- Migration and mapping of user identities and group memberships.
- Re-establishment of permissions, access levels, and security configurations.
- Migration of service connections, service principals, and managed identities.
- Update of all third-party integrations and extensions.
- Validation and post-migration testing.

### Out of Scope

- Azure DevOps Server (on-premises) migrations.
- Migration of Azure DevOps data (repos, pipelines, work items) between organizations — data remains in the same organization; only the backing directory changes.

### Objectives

- Ensure zero data loss during migration.
- Minimize user disruption and downtime.
- Maintain security posture and compliance.
- Document all steps for repeatability and auditability.

---

## 3. Prerequisites and Third-Party Dependencies

### Azure and Microsoft Dependencies

| Dependency | Description | Required |
|---|---|---|
| **Microsoft Entra ID (Azure AD) — Source Tenant** | contoso.com tenant with Global Administrator or Privileged Role Administrator access | ✅ Yes |
| **Microsoft Entra ID (Azure AD) — Target Tenant** | zava.com tenant with Global Administrator or Privileged Role Administrator access | ✅ Yes |
| **Azure DevOps Organization** | Organization Owner or Project Collection Administrator role | ✅ Yes |
| **Azure Subscriptions** | Access to all Azure subscriptions linked to service connections | ✅ Yes |
| **Microsoft 365 Licenses** | Appropriate licensing for users in the target tenant | ✅ Yes |
| **Azure Key Vault** | If secrets/certificates are used by pipelines | ⚠️ Conditional |
| **Azure Container Registry** | If container images are referenced in pipelines | ⚠️ Conditional |
| **Azure Resource Manager (ARM)** | For service connections to Azure resources | ✅ Yes |

### Third-Party Dependencies

| Dependency | Impact | Action Required |
|---|---|---|
| **GitHub integrations** | Service connections, webhooks, and OAuth apps linked to contoso.com identities | Reconfigure with zava.com identities |
| **Slack / Microsoft Teams notifications** | Webhook integrations may reference old identity context | Update notification configurations |
| **SonarQube / SonarCloud** | Service connections and authentication tokens | Regenerate tokens with new identities |
| **Marketplace Extensions** | Extensions installed in the organization may use identity-based permissions | Review and re-authorize extensions |
| **NuGet / npm / Maven feeds** | Upstream sources and feed permissions tied to identities | Update permissions for new identities |
| **Terraform / Ansible / Pulumi** | IaC tools using service principals from contoso.com tenant | Create new service principals in zava.com |
| **External Git repositories** | SSH keys and PATs tied to contoso.com users | Regenerate credentials |
| **SAML/SSO Providers** | If using external SAML SSO with contoso.com | Reconfigure for zava.com |

### Tools Required

- [Azure CLI](https://learn.microsoft.com/en-us/cli/azure/install-azure-cli) (`az` command)
- [Azure DevOps CLI extension](https://learn.microsoft.com/en-us/azure/devops/cli/) (`az devops`)
- [Microsoft Graph PowerShell SDK](https://learn.microsoft.com/en-us/powershell/microsoftgraph/installation)
- [AzureAD / Microsoft.Graph PowerShell modules](https://learn.microsoft.com/en-us/powershell/azure/active-directory/overview)
- [GitHub Copilot](https://github.com/features/copilot) (for AI-assisted scripting)

---

## 4. Users and Groups Migration in Microsoft Entra ID

### Overview

The most critical and complex part of the tenant migration is the identity migration. Every user and group in Azure DevOps is backed by an identity in Microsoft Entra ID. When you switch the organization's backing directory from contoso.com to zava.com, Azure DevOps will attempt to map existing users to identities in the new tenant.

### User Migration Strategy

#### Step 1 — Inventory Existing Users

Before migration, perform a complete inventory of all users in the Azure DevOps organization:

- **List all users** with their Entra ID User Principal Names (UPNs), display names, and access levels (Basic, Stakeholder, Visual Studio Subscriber, etc.).
- **Document access levels** and license assignments.
- **Export group memberships** for all Azure DevOps security groups and teams.
- **Record personal access tokens (PATs)**, SSH keys, and alternate credentials — these will be invalidated after migration and must be regenerated.

Use the Azure DevOps REST API or CLI to export this information:

```bash
az devops user list --organization https://dev.azure.com/{org} --output table
```

#### Step 2 — Provision Users in the Target Tenant (zava.com)

Users must exist in the zava.com Entra ID tenant before the directory switch:

- **Create user accounts** in zava.com with matching attributes (display name, email, etc.).
- **Use Microsoft Entra Connect** (Azure AD Connect) if synchronizing from an on-premises Active Directory to the new tenant.
- **For cloud-only users**, create them directly in the Entra ID portal or via PowerShell/Graph API:

```powershell
# Using Microsoft Graph PowerShell
Connect-MgGraph -Scopes "User.ReadWrite.All"

New-MgUser -DisplayName "John Doe" `
  -UserPrincipalName "john.doe@zava.com" `
  -MailNickname "john.doe" `
  -AccountEnabled `
  -PasswordProfile @{
    ForceChangePasswordNextSignIn = $true
    Password = "TemporaryP@ssw0rd!"
  }
```

- **Ensure UPN mapping** — if a user was `john.doe@contoso.com`, they should be `john.doe@zava.com` in the new tenant. Azure DevOps uses UPN prefix matching during the directory switch.

#### Step 3 — Migrate Groups

Groups in Azure DevOps can be:

- **Azure DevOps-managed groups** (e.g., Project Administrators, Contributors) — these are internal to Azure DevOps and persist after migration, but their members need re-mapping.
- **Entra ID groups** — if you have added Entra ID security groups or Microsoft 365 groups directly to Azure DevOps, you must recreate these groups in the zava.com tenant.

For Entra ID groups:

```powershell
# Export groups from source tenant
Connect-MgGraph -TenantId "contoso.com"
$groups = Get-MgGroup -All | Select-Object DisplayName, Id, Description, GroupTypes

# Create groups in target tenant
Connect-MgGraph -TenantId "zava.com"
foreach ($group in $groups) {
    New-MgGroup -DisplayName $group.DisplayName `
      -Description $group.Description `
      -MailEnabled:$false `
      -SecurityEnabled:$true `
      -MailNickname ($group.DisplayName -replace '\s','')
}
```

#### Step 4 — Map User Identities

Azure DevOps performs identity mapping during the directory switch based on:

1. **UPN match** — The user's UPN in the source tenant matches a UPN in the target tenant (e.g., `john.doe@contoso.com` → `john.doe@zava.com`).
2. **Email match** — If UPN doesn't match, Azure DevOps will try matching by email address.
3. **Display name match** — Last resort matching by display name.

> ⚠️ **Important**: Users that cannot be automatically mapped will lose access to the organization. It is critical to ensure all users have corresponding accounts in the target tenant before performing the switch.

#### Step 5 — Handle Guest Users (B2B)

If your organization includes guest users (B2B) from external tenants:

- Guest users from contoso.com who are accessing Azure DevOps will need to be re-invited as guests in zava.com.
- External guest users from other tenants (e.g., partner@fabrikam.com) will need to be re-invited via zava.com.

```powershell
# Invite guest user to new tenant
New-MgInvitation -InvitedUserEmailAddress "partner@fabrikam.com" `
  -InviteRedirectUrl "https://dev.azure.com/{org}" `
  -SendInvitationMessage:$true
```

#### Step 6 — Validate Identity Mapping

Before the actual switch, use the Azure DevOps identity mapping tool to preview how users will be mapped. This is available during the directory switch process in the Azure DevOps portal and allows you to:

- Review automatic mappings.
- Manually map users that couldn't be automatically matched.
- Identify users who will lose access.

### Entra ID Conditional Access and Security Policies

After migration, review and recreate (if needed) the following in the zava.com tenant:

- **Conditional Access Policies** targeting Azure DevOps.
- **Multi-Factor Authentication (MFA)** requirements.
- **Named Locations** and IP-based restrictions.
- **Terms of Use** policies.
- **Identity Protection** policies.

---

## 5. Migration Plan — Prioritized Steps

| Priority | Step | Description | Complexity | Risk | Estimated Duration |
|---|---|---|---|---|---|
| **P0** | Pre-migration assessment | Inventory all users, groups, service connections, extensions, and integrations | 🟡 Medium | 🟢 Low | 1–2 weeks |
| **P0** | Stakeholder communication | Notify all teams, set migration windows, and establish communication channels | 🟢 Low | 🟡 Medium | 1 week |
| **P1** | Provision users in zava.com tenant | Create all user accounts in the target Entra ID tenant | 🟡 Medium | 🔴 High | 1–2 weeks |
| **P1** | Recreate Entra ID groups in zava.com | Recreate security groups and Microsoft 365 groups | 🟡 Medium | 🔴 High | 1 week |
| **P1** | Configure Entra ID policies | Set up Conditional Access, MFA, and security policies in zava.com | 🟡 Medium | 🔴 High | 1 week |
| **P2** | Create service principals in zava.com | Recreate all app registrations and service principals | 🔴 High | 🔴 High | 1–2 weeks |
| **P2** | Pre-migration backup | Export all Azure DevOps configurations, permissions, and settings | 🟡 Medium | 🟢 Low | 2–3 days |
| **P3** | Perform directory switch | Execute the Azure DevOps organization directory change | 🔴 High | 🔴 High | 2–4 hours (downtime) |
| **P3** | Identity mapping validation | Review and fix user identity mappings during the switch | 🔴 High | 🔴 High | 1–2 hours |
| **P4** | Post-migration: Restore permissions | Verify and fix all permission assignments | 🟡 Medium | 🔴 High | 1–2 days |
| **P4** | Post-migration: Reconfigure service connections | Update all service connections with new service principals | 🔴 High | 🔴 High | 1–2 days |
| **P4** | Post-migration: Regenerate PATs and SSH keys | Users regenerate personal access tokens and SSH keys | 🟢 Low | 🟡 Medium | 1–3 days |
| **P5** | Post-migration: Test pipelines | Run all CI/CD pipelines to verify functionality | 🟡 Medium | 🟡 Medium | 2–3 days |
| **P5** | Post-migration: Validate integrations | Test all third-party integrations | 🟡 Medium | 🟡 Medium | 1–2 days |
| **P5** | Post-migration: User acceptance testing | Have teams validate their workflows | 🟢 Low | 🟢 Low | 1 week |
| **P6** | Decommission old tenant references | Remove contoso.com references and clean up | 🟢 Low | 🟢 Low | 1 week |

### Risk Matrix

| Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|
| Users unable to sign in after migration | Medium | High | Pre-validate identity mapping; keep contoso.com accounts active during transition |
| Pipeline failures due to broken service connections | High | High | Document all service connections; pre-create service principals in zava.com |
| Loss of permissions and access levels | Medium | High | Export all permissions before migration; use scripts to restore |
| Extended downtime during switch | Low | High | Perform switch during off-hours; have rollback plan ready |
| Third-party integration failures | Medium | Medium | Test integrations in a staging environment when possible |
| PAT and SSH key invalidation disrupting automation | High | Medium | Notify users in advance; provide self-service regeneration guides |

---

## 6. Detailed Migration Steps

### Phase 1 — Assessment and Planning (2–4 weeks before migration)

#### 1.1 Inventory Azure DevOps Organization

```bash
# List all projects
az devops project list --organization https://dev.azure.com/{org}

# List all users and their access levels
az devops user list --organization https://dev.azure.com/{org} --output json > users_export.json

# List all service connections (per project)
az devops service-endpoint list --organization https://dev.azure.com/{org} --project {project}

# List all installed extensions
az devops extension list --organization https://dev.azure.com/{org}
```

#### 1.2 Inventory Entra ID (Source Tenant — contoso.com)

```powershell
Connect-MgGraph -TenantId "contoso.com" -Scopes "User.Read.All","Group.Read.All","Application.Read.All"

# Export all users
Get-MgUser -All | Export-Csv -Path "contoso_users.csv" -NoTypeInformation

# Export all groups and their members
$groups = Get-MgGroup -All
foreach ($group in $groups) {
    $members = Get-MgGroupMember -GroupId $group.Id -All
    [PSCustomObject]@{
        GroupName = $group.DisplayName
        GroupId   = $group.Id
        Members   = ($members.AdditionalProperties.userPrincipalName -join "; ")
    }
} | Export-Csv -Path "contoso_groups.csv" -NoTypeInformation

# Export app registrations
Get-MgApplication -All | Export-Csv -Path "contoso_apps.csv" -NoTypeInformation
```

#### 1.3 Prepare Communication Plan

- Notify all Azure DevOps users about the upcoming migration.
- Publish a timeline with key dates and expected downtime.
- Provide a FAQ document addressing common user concerns.
- Establish a support channel (e.g., Teams channel, email alias) for migration-related questions.

### Phase 2 — Preparation (1–2 weeks before migration)

#### 2.1 Provision Users and Groups in zava.com

Follow the detailed steps in [Section 4 — Users and Groups Migration](#4-users-and-groups-migration-in-microsoft-entra-id).

#### 2.2 Create Service Principals and App Registrations

For each service connection in Azure DevOps that uses a service principal from contoso.com:

1. Create a corresponding app registration in zava.com.
2. Grant the necessary API permissions.
3. Create client secrets or certificates.
4. Assign the appropriate RBAC roles on Azure resources.

```powershell
# Create app registration in zava.com
Connect-MgGraph -TenantId "zava.com" -Scopes "Application.ReadWrite.All"

$app = New-MgApplication -DisplayName "AzDevOps-ServiceConnection-{name}" `
  -SignInAudience "AzureADMyOrg"

# Create service principal
New-MgServicePrincipal -AppId $app.AppId

# Create client secret
$secret = Add-MgApplicationPassword -ApplicationId $app.Id `
  -PasswordCredential @{ DisplayName = "AzDevOps"; EndDateTime = (Get-Date).AddYears(1) }
```

#### 2.3 Update Azure RBAC Assignments

If Azure resources (subscriptions, resource groups) are also moving to the zava.com tenant, update RBAC role assignments:

```bash
# Assign role to new service principal
az role assignment create \
  --assignee {new-sp-object-id} \
  --role "Contributor" \
  --scope "/subscriptions/{subscription-id}"
```

#### 2.4 Back Up Azure DevOps Configurations

- Export team and area/iteration configurations.
- Export security/permission settings using the Azure DevOps REST API.
- Document all pipeline variable groups and their values.
- Take note of repository policies and branch protection rules.

### Phase 3 — Execute Directory Switch (Migration Day)

#### 3.1 Pre-Switch Checks

- [ ] Confirm all users exist in zava.com tenant.
- [ ] Confirm all required groups exist in zava.com tenant.
- [ ] Confirm all service principals are created in zava.com.
- [ ] Confirm rollback plan is documented and ready.
- [ ] Notify all users that migration is starting.

#### 3.2 Perform the Directory Switch

1. Sign in to [Azure DevOps](https://dev.azure.com) as the **Organization Owner**.
2. Navigate to **Organization Settings** → **Azure Active Directory**.
3. Click **Switch directory**.
4. Select the **zava.com** tenant as the target directory.
5. Review the identity mapping — Azure DevOps will show how users from contoso.com will be mapped to zava.com.
6. Manually fix any unmapped or incorrectly mapped users.
7. Confirm the switch.

> ⚠️ **Important**: During the directory switch, users will temporarily lose access to the Azure DevOps organization. Plan this during a maintenance window.

#### 3.3 Post-Switch Immediate Actions

- Verify that the organization is connected to zava.com.
- Test sign-in with several user accounts.
- Verify Organization Owner access.
- Check Project Collection Administrator access.

### Phase 4 — Post-Migration Validation (1–2 weeks after migration)

#### 4.1 Verify User Access

- Confirm all users can sign in.
- Verify access levels (Basic, Stakeholder, VS Subscriber) are correctly assigned.
- Check team memberships.
- Validate project-level permissions.

#### 4.2 Reconfigure Service Connections

Update all service connections to use the new service principals from zava.com:

```bash
# Update a service connection (example using REST API)
az devops service-endpoint update \
  --id {endpoint-id} \
  --organization https://dev.azure.com/{org} \
  --project {project}
```

#### 4.3 Regenerate Personal Access Tokens

All existing PATs will be invalidated. Users must create new PATs:

1. Navigate to [https://dev.azure.com/{org}/_usersSettings/tokens](https://dev.azure.com/{org}/_usersSettings/tokens).
2. Create new PATs as needed.
3. Update any automation that uses PATs.

#### 4.4 Regenerate SSH Keys

Users who use SSH for Git operations must add new SSH keys associated with their zava.com identity.

#### 4.5 Run CI/CD Pipeline Validation

- Trigger builds for all critical pipelines.
- Verify that pipeline agents can authenticate.
- Check that artifact feeds are accessible.
- Validate deployment pipelines to all environments.

#### 4.6 Test Third-Party Integrations

- Verify GitHub integration (if applicable).
- Test Slack/Teams notifications.
- Validate SonarQube/SonarCloud connections.
- Check marketplace extension functionality.

---

## 7. Leveraging AI Tools (GitHub Copilot) for Migration Automation

### Accelerating Migration with AI-Powered Tooling

The operations (ops) team can significantly accelerate the Azure DevOps tenant migration by leveraging AI tools such as **GitHub Copilot**, **GitHub Copilot Chat**, and **GitHub Copilot for CLI**. These tools provide substantial benefits at every phase of the migration:

**Script Generation and Automation** — GitHub Copilot excels at generating PowerShell, Azure CLI, and REST API scripts needed throughout the migration. For example, ops engineers can describe the intent (e.g., "export all Azure DevOps users and their group memberships to a CSV file") and Copilot will generate production-ready scripts, including error handling and logging. This dramatically reduces the time spent writing boilerplate code and avoids common syntax errors in complex API calls. For bulk operations like provisioning hundreds of users in the new Entra ID tenant or recreating group memberships, Copilot can generate parameterized scripts that handle pagination, throttling, and retry logic — patterns that are tedious and error-prone to implement manually.

**Reducing Human Errors** — Manual migration tasks are inherently risky because they involve repetitive actions across multiple systems. AI-assisted scripting ensures consistency: once Copilot generates a script for one service connection migration, the same pattern is reliably applied to all service connections. Copilot Chat can also review existing scripts for potential issues, suggest improvements, and help engineers understand complex Azure DevOps REST API responses.

**Knowledge Assistance** — GitHub Copilot Chat serves as an on-demand knowledge base during migration. Engineers can ask questions like "What permissions are needed to switch an Azure DevOps organization directory?" or "How do I handle guest users during a tenant migration?" and receive contextual, accurate answers without leaving their IDE. This reduces the time spent searching documentation and helps less experienced team members contribute effectively to the migration effort.

**Infrastructure as Code** — Copilot can help generate Terraform, Bicep, or ARM templates for recreating Azure infrastructure components (service principals, RBAC assignments, Key Vault access policies) in the new tenant. This ensures that infrastructure changes are version-controlled, reviewable, and repeatable.

**Post-Migration Validation** — AI tools can help generate comprehensive test scripts that validate every aspect of the migration: user access verification, pipeline execution tests, service connection health checks, and integration validation. Copilot can generate test matrices that cover edge cases an engineer might overlook.

> 💡 **Recommendation**: Establish a shared repository (like this one) where the ops team collaborates on migration scripts. Use GitHub Copilot directly in VS Code or the GitHub web editor to iteratively build and refine scripts. Leverage Copilot Chat to troubleshoot issues in real time during the migration execution.

---

## 8. Migration Checklist

### Pre-Migration (2–4 Weeks Before)

- [ ] Identify and document the Azure DevOps Organization Owner and Project Collection Administrators.
- [ ] Obtain Global Administrator access to both contoso.com and zava.com Entra ID tenants.
- [ ] Inventory all Azure DevOps users, access levels, and licenses.
- [ ] Inventory all Azure DevOps groups (Entra ID groups and Azure DevOps-managed groups).
- [ ] Inventory all service connections across all projects.
- [ ] Inventory all installed marketplace extensions.
- [ ] Inventory all PATs and SSH keys (notify owners about invalidation).
- [ ] Inventory all pipeline agent pools and agent registrations.
- [ ] Document all third-party integrations (GitHub, Slack, SonarQube, etc.).
- [ ] Document all Azure RBAC role assignments for service principals.
- [ ] Create a communication plan and notify all stakeholders.
- [ ] Schedule the migration window (off-hours recommended).
- [ ] Document the rollback plan.

### Preparation (1–2 Weeks Before)

- [ ] Provision all user accounts in the zava.com Entra ID tenant.
- [ ] Verify UPN mapping between contoso.com and zava.com users.
- [ ] Recreate all Entra ID security groups in zava.com.
- [ ] Recreate all Entra ID Microsoft 365 groups in zava.com (if used).
- [ ] Populate group memberships in zava.com.
- [ ] Create all app registrations and service principals in zava.com.
- [ ] Generate client secrets/certificates for new service principals.
- [ ] Assign Azure RBAC roles to new service principals.
- [ ] Configure Conditional Access policies in zava.com for Azure DevOps.
- [ ] Set up MFA policies in zava.com.
- [ ] Back up all Azure DevOps organization settings and permissions.
- [ ] Test user sign-in to zava.com tenant (outside of Azure DevOps).
- [ ] Send final migration notification to all users.

### Migration Day

- [ ] Send "migration starting" notification.
- [ ] Pause or disable non-critical CI/CD pipelines.
- [ ] Perform the directory switch in Azure DevOps Organization Settings.
- [ ] Review and validate identity mappings.
- [ ] Manually map any unmatched users.
- [ ] Confirm the directory switch.
- [ ] Verify Organization Owner can sign in via zava.com.
- [ ] Verify Project Collection Administrators can sign in.
- [ ] Spot-check several regular user accounts.
- [ ] Send "migration complete" notification with next steps.

### Post-Migration (1–2 Weeks After)

- [ ] Verify all users can sign in to Azure DevOps with zava.com credentials.
- [ ] Verify all access levels are correctly assigned.
- [ ] Verify team and group memberships.
- [ ] Reconfigure all service connections with zava.com service principals.
- [ ] Validate all CI/CD pipelines run successfully.
- [ ] Verify artifact feed access (NuGet, npm, Maven, etc.).
- [ ] Verify Azure Artifacts upstream sources.
- [ ] Have users regenerate PATs.
- [ ] Have users re-add SSH keys.
- [ ] Test all third-party integrations.
- [ ] Validate Azure Boards queries and dashboards.
- [ ] Validate Azure Test Plans.
- [ ] Validate wiki access and permissions.
- [ ] Update any documentation referencing contoso.com.
- [ ] Update any automation scripts referencing contoso.com identities.
- [ ] Update DNS records if applicable.
- [ ] Monitor support channel for user-reported issues.

### Cleanup (2–4 Weeks After)

- [ ] Remove temporary contoso.com admin accounts (if created for migration).
- [ ] Remove old service principals from contoso.com (after confirming no dependencies).
- [ ] Archive migration scripts and documentation.
- [ ] Conduct post-migration retrospective.
- [ ] Close migration project.

---

## 9. Rollback Plan

In case the directory switch causes critical issues that cannot be resolved:

1. **Azure DevOps allows switching back** to the original directory within a limited time frame. The Organization Owner can navigate to **Organization Settings → Azure Active Directory** and switch back to contoso.com.
2. Ensure contoso.com user accounts are **not deleted or disabled** during the migration window.
3. Keep all contoso.com service principals and app registrations active until the migration is fully validated.
4. Document the exact rollback steps and assign a rollback owner before starting the migration.

> ⚠️ **Note**: Switching back will also require users to use their original contoso.com credentials. Any changes made in Azure DevOps after the switch (new PATs, updated permissions) may be lost.

---

## 10. Microsoft Official References

### Azure DevOps Documentation

- [Change your organization connection to a different Azure AD](https://learn.microsoft.com/en-us/azure/devops/organizations/accounts/change-azure-ad-connection) — Primary guide for switching the backing directory of an Azure DevOps organization.
- [Connect your organization to Azure Active Directory](https://learn.microsoft.com/en-us/azure/devops/organizations/accounts/connect-organization-to-azure-ad) — Initial setup of Entra ID connection.
- [Access with Azure AD FAQ](https://learn.microsoft.com/en-us/azure/devops/organizations/accounts/faq-azure-access) — Frequently asked questions about Azure DevOps and Entra ID integration.
- [Manage users and access in Azure DevOps](https://learn.microsoft.com/en-us/azure/devops/organizations/accounts/add-organization-users) — Managing user access and licenses.
- [Azure DevOps Services REST API](https://learn.microsoft.com/en-us/rest/api/azure/devops/) — API reference for automation.
- [Azure DevOps CLI](https://learn.microsoft.com/en-us/azure/devops/cli/) — Command-line interface for Azure DevOps.

### Microsoft Entra ID (Azure AD) Documentation

- [Microsoft Entra ID documentation](https://learn.microsoft.com/en-us/entra/identity/) — Comprehensive Entra ID documentation.
- [Create users in Microsoft Entra ID](https://learn.microsoft.com/en-us/entra/fundamentals/how-to-create-delete-users) — Creating and managing users.
- [Manage groups in Microsoft Entra ID](https://learn.microsoft.com/en-us/entra/fundamentals/how-to-manage-groups) — Creating and managing groups.
- [Microsoft Entra B2B collaboration](https://learn.microsoft.com/en-us/entra/external-id/what-is-b2b) — Guest user management.
- [Conditional Access in Microsoft Entra ID](https://learn.microsoft.com/en-us/entra/identity/conditional-access/overview) — Conditional Access policies.
- [Microsoft Graph API](https://learn.microsoft.com/en-us/graph/overview) — API for Entra ID management.
- [Microsoft Graph PowerShell SDK](https://learn.microsoft.com/en-us/powershell/microsoftgraph/overview) — PowerShell module for Microsoft Graph.

### Azure Documentation

- [Azure RBAC documentation](https://learn.microsoft.com/en-us/azure/role-based-access-control/overview) — Role-based access control for Azure resources.
- [Azure CLI documentation](https://learn.microsoft.com/en-us/cli/azure/) — Azure command-line interface.
- [Transfer Azure subscriptions between tenants](https://learn.microsoft.com/en-us/azure/role-based-access-control/transfer-subscription) — Transferring subscriptions to a new tenant.
- [Azure Key Vault — Move to a different tenant](https://learn.microsoft.com/en-us/azure/key-vault/general/move-subscription) — Key Vault tenant migration.

### GitHub Copilot

- [GitHub Copilot documentation](https://docs.github.com/en/copilot) — Getting started with GitHub Copilot.
- [GitHub Copilot for CLI](https://docs.github.com/en/copilot/using-github-copilot/using-github-copilot-in-the-command-line) — Using Copilot in the terminal.

---

*Document version: 1.0*
*Last updated: 2026-03-13*
*Author: Migration Team*
