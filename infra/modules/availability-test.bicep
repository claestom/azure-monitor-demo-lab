// =====================================================================================
// Standard Availability Test (URL ping) on an App Service endpoint.
// Tests from 5 global locations every 5 minutes, wired to an Action Group.
// =====================================================================================

@description('Name of the availability test.')
param name string

@description('Region (must match App Insights region).')
param location string

@description('Resource ID of the Application Insights instance.')
param appInsightsId string

@description('URL to test (e.g. https://app-<namePrefix>-<suffix>.azurewebsites.net/).')
param testUrl string

@description('Action Group resource ID for failure alerts.')
param actionGroupId string

@description('Resource tags.')
param tags object = {}

// Global test locations: US-East, US-West, UK-South, North Europe, Southeast Asia
var testLocations = [
  { Id: 'us-tx-sn1-azr' }   // South Central US
  { Id: 'us-il-ch1-azr' }   // North Central US
  { Id: 'emea-gb-db3-azr' } // UK South
  { Id: 'emea-nl-ams-azr' } // West Europe
  { Id: 'apac-sg-sin-azr' } // Southeast Asia
]

resource availabilityTest 'Microsoft.Insights/webtests@2022-06-15' = {
  name: name
  location: location
  tags: union(tags, {
    // This hidden tag links the webtest to App Insights (required)
    'hidden-link:${appInsightsId}': 'Resource'
  })
  kind: 'standard'
  properties: {
    SyntheticMonitorId: name
    Name: name
    Description: 'Standard URL ping test for the demo App Service — tests from 5 global locations every 5 min.'
    Enabled: true
    Frequency: 300
    Timeout: 120
    Kind: 'standard'
    RetryEnabled: true
    Locations: testLocations
    Request: {
      RequestUrl: testUrl
      HttpVerb: 'GET'
      ParseDependentRequests: false
      FollowRedirects: true
    }
    ValidationRules: {
      ExpectedHttpStatusCode: 200
      SSLCheck: true
      SSLCertRemainingLifetimeCheck: 7
    }
  }
}

// Alert rule that fires when the test fails from ≥ 2 locations
resource availabilityAlert 'Microsoft.Insights/metricAlerts@2018-03-01' = {
  name: 'alert-${name}'
  location: 'global'
  tags: tags
  properties: {
    description: 'Availability test "${name}" failing from 2+ global locations.'
    severity: 1
    enabled: true
    scopes: [
      appInsightsId
      availabilityTest.id
    ]
    evaluationFrequency: 'PT1M'
    windowSize: 'PT5M'
    criteria: {
      'odata.type': 'Microsoft.Azure.Monitor.WebtestLocationAvailabilityCriteria'
      webTestId: availabilityTest.id
      componentId: appInsightsId
      failedLocationCount: 2
    }
    actions: [
      { actionGroupId: actionGroupId }
    ]
  }
}

output testId string = availabilityTest.id
output testName string = availabilityTest.name
