@description('Region for scheduled query alerts.')
param location string

@description('Central Log Analytics workspace resource ID.')
param workspaceId string

@description('Action group resource ID.')
param actionGroupId string

@description('Resource tags.')
param tags object = {}

resource controlPlaneDrift 'Microsoft.Insights/scheduledQueryRules@2023-03-15-preview' = {
  name: 'alert-security-control-plane-drift'
  location: location
  tags: tags
  properties: {
    description: 'Control-plane drift watch: unusual bursts of write/delete operations.'
    enabled: true
    severity: 2
    scopes: [ workspaceId ]
    evaluationFrequency: 'PT5M'
    windowSize: 'PT15M'
    criteria: {
      allOf: [
        {
          query: 'AzureActivity | where TimeGenerated > ago(15m) | where ActivityStatusValue == "Success" | where OperationNameValue has_any ("/write", "/delete", "/action") | summarize Changes = count()'
          timeAggregation: 'Count'
          operator: 'GreaterThan'
          threshold: 40
          failingPeriods: {
            numberOfEvaluationPeriods: 1
            minFailingPeriodsToAlert: 1
          }
        }
      ]
    }
    autoMitigate: true
    actions: {
      actionGroups: [ actionGroupId ]
    }
  }
}

resource privilegeEscalation 'Microsoft.Insights/scheduledQueryRules@2023-03-15-preview' = {
  name: 'alert-security-privilege-escalation-watch'
  location: location
  tags: tags
  properties: {
    description: 'Privilege escalation watch: high-risk RBAC mutations in activity logs.'
    enabled: true
    severity: 1
    scopes: [ workspaceId ]
    evaluationFrequency: 'PT5M'
    windowSize: 'PT30M'
    criteria: {
      allOf: [
        {
          query: 'AzureActivity | where TimeGenerated > ago(30m) | where ActivityStatusValue == "Success" | where OperationNameValue has_any ("roleAssignments/write", "roleDefinitions/write", "elevateAccess/action") | summarize Hits = count()'
          timeAggregation: 'Count'
          operator: 'GreaterThan'
          threshold: 0
          failingPeriods: {
            numberOfEvaluationPeriods: 1
            minFailingPeriodsToAlert: 1
          }
        }
      ]
    }
    autoMitigate: true
    actions: {
      actionGroups: [ actionGroupId ]
    }
  }
}

resource exfilEarlyWarning 'Microsoft.Insights/scheduledQueryRules@2023-03-15-preview' = {
  name: 'alert-security-exfil-early-warning'
  location: location
  tags: tags
  properties: {
    description: 'Exfiltration early warning: outbound traffic spikes in flow analytics.'
    enabled: true
    severity: 2
    // NTANetAnalytics schema is only populated once VNet Flow Logs + Traffic
    // Analytics have ingested data. Skip pre-validation so the deployment
    // succeeds against an empty workspace; the rule evaluates correctly at
    // runtime once data flows.
    skipQueryValidation: true
    scopes: [ workspaceId ]
    evaluationFrequency: 'PT5M'
    windowSize: 'PT30M'
    criteria: {
      allOf: [
        {
          query: 'NTANetAnalytics | where TimeGenerated > ago(30m) | where SubType == "FlowLog" | where FlowDirection == "O" | summarize OutboundBytes = sum(BytesSrcToDest) | where OutboundBytes > 1000000000'
          timeAggregation: 'Count'
          operator: 'GreaterThan'
          threshold: 0
          failingPeriods: {
            numberOfEvaluationPeriods: 1
            minFailingPeriodsToAlert: 1
          }
        }
      ]
    }
    autoMitigate: true
    actions: {
      actionGroups: [ actionGroupId ]
    }
  }
}
