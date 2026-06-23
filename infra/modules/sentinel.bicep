// =====================================================================================
// Microsoft Sentinel — onboard the central LAW and add one Scheduled Analytics Rule.
//
//   * Onboarding = install the `SecurityInsights(<lawName>)` solution. Once that
//     lands, the LAW is "Sentinel-enabled" and the Sentinel blade is available.
//   * We add ONE rule that pivots off AzureActivity (already flowing into the LAW)
//     so Sentinel has a real incident to show during the demo.
//
// Cost note: Sentinel reuses the LAW; ingestion costs the same — there's a separate
// per-GB analytics fee on top, but at lab volumes this is pennies.
// =====================================================================================

@description('Central LAW name.')
param workspaceName string

@description('Central LAW resource ID.')
param workspaceId string

@description('Region.')
param location string

@description('Resource tags.')
param tags object = {}

// ---------------------------------------------------------------------------------
// 1. Onboard Sentinel onto the workspace (via the OperationsManagement solution
//    pattern — same approach as VMInsights / ContainerInsights elsewhere in the lab).
// ---------------------------------------------------------------------------------
resource sentinelSolution 'Microsoft.OperationsManagement/solutions@2015-11-01-preview' = {
  name: 'SecurityInsights(${workspaceName})'
  location: location
  tags: tags
  properties: {
    workspaceResourceId: workspaceId
  }
  plan: {
    name: 'SecurityInsights(${workspaceName})'
    product: 'OMSGallery/SecurityInsights'
    publisher: 'Microsoft'
    promotionCode: ''
  }
}

// ---------------------------------------------------------------------------------
// 2. Sentinel onboarding state — explicit `onboardingStates` resource so we can
//    take dependencies on it from the analytics rule below.
// ---------------------------------------------------------------------------------
resource lawRef 'Microsoft.OperationalInsights/workspaces@2023-09-01' existing = {
  name: workspaceName
}

resource sentinelOnboarding 'Microsoft.SecurityInsights/onboardingStates@2024-09-01' = {
  scope: lawRef
  name: 'default'
  properties: {}
  dependsOn: [ sentinelSolution ]
}

// ---------------------------------------------------------------------------------
// 3. One Scheduled Analytics Rule — fire if anyone deletes a resource in the RG
//    outside of a known service principal. Pure demo material; thresholds are
//    intentionally low so the rule actually triggers.
// ---------------------------------------------------------------------------------
resource ruleDelete 'Microsoft.SecurityInsights/alertRules@2024-09-01' = {
  scope: lawRef
  name: '0a1b2c3d-amlab-rg-delete-alert'
  kind: 'Scheduled'
  properties: {
    displayName: 'amlab — Resource deletion in lab RG'
    description: 'Demo Sentinel rule: any successful delete operation in the lab RG over the last 1h.'
    severity: 'Medium'
    enabled: true
    query: 'AzureActivity\n| where TimeGenerated > ago(1h)\n| where ActivityStatusValue == "Success"\n| where OperationNameValue endswith "/delete"\n| project TimeGenerated, Caller, OperationNameValue, _ResourceId'
    queryFrequency: 'PT15M'
    queryPeriod: 'PT1H'
    triggerOperator: 'GreaterThan'
    triggerThreshold: 0
    suppressionDuration: 'PT1H'
    suppressionEnabled: false
    tactics: [ 'Impact' ]
    techniques: [ 'T1485' ]
    // One alert per matching row so the SOC sees the full blast radius
    // (each child resource + the RG itself), all grouped into a single
    // incident by the incidentConfiguration below.
    eventGroupingSettings: {
      aggregationKind: 'AlertPerResult'
    }
    entityMappings: [
      {
        entityType: 'Account'
        fieldMappings: [
          { identifier: 'FullName', columnName: 'Caller' }
        ]
      }
      {
        entityType: 'AzureResource'
        fieldMappings: [
          { identifier: 'ResourceId', columnName: '_ResourceId' }
        ]
      }
    ]
    incidentConfiguration: {
      createIncident: true
      groupingConfiguration: {
        enabled: true
        reopenClosedIncident: false
        lookbackDuration: 'PT5H'
        // AnyAlert: every alert this rule fires within the lookback joins the
        // same incident — the blast-radius story stays as one incident even
        // when the deleted resources have different _ResourceId entities.
        matchingMethod: 'AnyAlert'
      }
    }
  }
  dependsOn: [ sentinelOnboarding ]
}

output sentinelOnboarded bool = true
output ruleName string = ruleDelete.name
