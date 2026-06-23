targetScope = 'resourceGroup'

@description('Azure region for all resources.')
param location string = resourceGroup().location

@description('Short prefix used to build resource names.')
@minLength(3)
@maxLength(8)
param namePrefix string = 'amlab'

@description('Tag every resource with this owner.')
param ownerTag string = 'demo-lab'

var suffix = uniqueString(resourceGroup().id)
var lawCentralName = 'law-${namePrefix}-central-${take(suffix, 5)}'
var actionGroupName = 'ag-${namePrefix}-email'
var securityWorkbookName = 'wb-${namePrefix}-security'

var commonTags = {
  owner: ownerTag
  purpose: 'azure-monitor-demo-lab'
  costCenter: 'demo'
}

resource lawCentral 'Microsoft.OperationalInsights/workspaces@2023-09-01' existing = {
  name: lawCentralName
}

resource actionGroup 'Microsoft.Insights/actionGroups@2023-09-01-preview' existing = {
  name: actionGroupName
}

module lawRbac '../modules/law-rbac.bicep' = {
  name: 'law-rbac'
  params: {
    centralLawId: lawCentral.id
    centralLawName: lawCentral.name
    location: location
    tags: commonTags
  }
}

module securityPostureAlerts '../modules/security-posture-alerts.bicep' = {
  name: 'security-posture-alerts'
  params: {
    location: location
    workspaceId: lawCentral.id
    actionGroupId: actionGroup.id
    tags: commonTags
  }
}

// ---------------------------------------------------------------------------------
// Security operations Workbook
//   Multi-section security pane-of-glass: identity (SigninLogs), control-plane
//   CRUD (AzureActivity), privilege escalation, network exfil (NTANetAnalytics),
//   lifecycle churn, sensitive data plane (Key Vault, Storage), linked alerts.
//   Backing alerts live in security-posture-alerts.bicep (scenarios 47, 48, 49).
// ---------------------------------------------------------------------------------
module securityWorkbook '../modules/security-workbook.bicep' = {
  name: 'security-workbook'
  params: {
    name: guid(resourceGroup().id, securityWorkbookName)
    location: location
    centralLawId: lawCentral.id
    tags: commonTags
  }
}

output securityWorkbookId string = securityWorkbook.outputs.id
