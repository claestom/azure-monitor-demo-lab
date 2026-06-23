// =====================================================================================
// Log Analytics Granular RBAC demo — workspace-level, table-level, and row-level
// access control using Azure ABAC (Attribute-Based Access Control) conditions.
//
// This module uses the GA Granular RBAC feature (Nov 2025):
//   https://learn.microsoft.com/azure/azure-monitor/logs/granular-rbac-log-analytics
//
// Creates custom roles with DataActions and demonstrates ABAC conditions for
// table-level and row-level filtering — all within a single workspace.
//
// NOTE: Role assignments with ABAC conditions require principalIds.
//       Pass real Entra ID object IDs, or assign them via the portal/CLI during demos.
// =====================================================================================

@description('Central LAW resource ID.')
param centralLawId string

@description('Central LAW name.')
param centralLawName string

@description('Region (unused — kept for consistency).')
#disable-next-line no-unused-params
param location string

@description('Resource tags (unused — kept for consistency).')
#disable-next-line no-unused-params
param tags object = {}

@description('(Optional) Object ID of a user/group for the "all-tables reader" role. Leave empty to skip.')
param workspaceReaderPrincipalId string = ''

@description('(Optional) Object ID of a user/group for the table-restricted role. Leave empty to skip.')
param tableReaderPrincipalId string = ''

@description('(Optional) Object ID of a user/group for the row-level filtered role. Leave empty to skip.')
param rowFilteredPrincipalId string = ''

resource centralLaw 'Microsoft.OperationalInsights/workspaces@2023-09-01' existing = {
  name: centralLawName
}

// ---------------------------------------------------------------------------------
// TIER 1 — Workspace-level: unrestricted data read (all tables, all rows)
//   Uses the built-in Log Analytics Reader for broad read access.
// ---------------------------------------------------------------------------------
var logAnalyticsReaderRoleId = '73c42c96-874c-492b-b04d-ab87d138a893'

resource wsReaderAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (!empty(workspaceReaderPrincipalId)) {
  name: guid(centralLawId, logAnalyticsReaderRoleId, workspaceReaderPrincipalId)
  scope: centralLaw
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', logAnalyticsReaderRoleId)
    principalId: workspaceReaderPrincipalId
    principalType: 'User'
  }
}

// ---------------------------------------------------------------------------------
// Granular RBAC custom role — used for TIER 2 and TIER 3 assignments.
//
// This role has the minimum Actions + DataActions required by Granular RBAC:
//   Actions:     workspaces/read, workspaces/query/read
//   DataActions: workspaces/tables/data/read
//
// The DataAction is what ABAC conditions filter on. Without conditions,
// this role grants read on ALL tables. With conditions, access is scoped
// to specific tables and/or specific row values.
// ---------------------------------------------------------------------------------
resource granularRole 'Microsoft.Authorization/roleDefinitions@2022-04-01' = {
  // Per-RG GUID so parallel lab deployments in the same subscription don't
  // collide on a subscription-scoped role definition (ARM forbids changing
  // assignableScopes while old assignments still exist at the prior scope).
  name: guid(resourceGroup().id, 'amlab-granular-log-reader')
  properties: {
    roleName: 'AMLAB - Granular Log Reader (${uniqueString(resourceGroup().id)})'
    description: 'Granular RBAC role for Log Analytics. Assign with ABAC conditions to restrict table or row-level access. Uses DataAction for data plane control.'
    type: 'CustomRole'
    permissions: [
      {
        actions: [
          'Microsoft.OperationalInsights/workspaces/read'
          'Microsoft.OperationalInsights/workspaces/query/read'
        ]
        notActions: []
        dataActions: [
          'Microsoft.OperationalInsights/workspaces/tables/data/read'
        ]
        notDataActions: []
      }
    ]
    assignableScopes: [
      resourceGroup().id
    ]
  }
}

// ---------------------------------------------------------------------------------
// TIER 2 — Table-level: ABAC restricts to SecurityAudit_CL only
//
// Condition logic (restrictive — "no access except what is allowed"):
//   IF action is tables/data/read
//     THEN table name must be SecurityAudit_CL
//
// ABAC condition expression:
//   (
//     !(ActionMatches{'Microsoft.OperationalInsights/workspaces/tables/data/read'})
//     OR
//     @Resource[Microsoft.OperationalInsights/workspaces/tables:name]
//       StringEquals 'SecurityAudit_CL'
//   )
// ---------------------------------------------------------------------------------
var tableCondition = '((!(ActionMatches{\'Microsoft.OperationalInsights/workspaces/tables/data/read\'})) OR (@Resource[Microsoft.OperationalInsights/workspaces/tables:name] StringEquals \'SecurityAudit_CL\'))'

resource tableReaderAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (!empty(tableReaderPrincipalId)) {
  name: guid(centralLawId, 'granular-table-reader', tableReaderPrincipalId)
  scope: centralLaw
  properties: {
    roleDefinitionId: granularRole.id
    principalId: tableReaderPrincipalId
    principalType: 'User'
    condition: tableCondition
    conditionVersion: '2.0'
  }
}

// ---------------------------------------------------------------------------------
// TIER 3 — Row-level: ABAC restricts to specific column values
//
// Condition logic (restrictive — "no access except what is allowed"):
//   IF action is tables/data/read
//     THEN table name must be SecurityAudit_CL
//     AND  Severity column must be 'Critical'
//
// This means the user can ONLY see Critical-severity events in SecurityAudit_CL.
// All other tables and all non-Critical rows are invisible.
//
// ABAC condition expression:
//   (
//     !(ActionMatches{'Microsoft.OperationalInsights/workspaces/tables/data/read'})
//     OR
//     (
//       @Resource[Microsoft.OperationalInsights/workspaces/tables:name]
//         StringEquals 'SecurityAudit_CL'
//       AND
//       @Resource[Microsoft.OperationalInsights/workspaces/tables/record:Severity<$key_case_sensitive$>]
//         StringEquals 'Critical'
//     )
//   )
// ---------------------------------------------------------------------------------
var rowCondition = '((!(ActionMatches{\'Microsoft.OperationalInsights/workspaces/tables/data/read\'})) OR ((@Resource[Microsoft.OperationalInsights/workspaces/tables:name] StringEquals \'SecurityAudit_CL\') AND (@Resource[Microsoft.OperationalInsights/workspaces/tables/record:Severity<$key_case_sensitive$>] StringEquals \'Critical\')))'

resource rowFilteredAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (!empty(rowFilteredPrincipalId)) {
  name: guid(centralLawId, 'granular-row-filtered', rowFilteredPrincipalId)
  scope: centralLaw
  properties: {
    roleDefinitionId: granularRole.id
    principalId: rowFilteredPrincipalId
    principalType: 'User'
    condition: rowCondition
    conditionVersion: '2.0'
  }
}

// ---------------------------------------------------------------------------------
// Outputs
// ---------------------------------------------------------------------------------
output granularRoleName string = granularRole.properties.roleName
output rbacSummary string = 'Granular RBAC deployed: (1) workspace-level via Log Analytics Reader, (2) table-level via ABAC condition restricting to SecurityAudit_CL, (3) row-level via ABAC condition filtering Severity==Critical only. Custom role "AMLAB - Granular Log Reader" uses DataActions for data plane control.'
