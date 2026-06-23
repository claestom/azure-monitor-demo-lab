@description('Action Group name.')
param name string

@description('Email recipient for the Action Group.')
param email string

@description('Optional webhook URL (e.g., auto-mitigation Logic App callback URL). Leave empty to skip.')
@secure()
param webhookUrl string = ''

@description('Optional secondary webhook URL (e.g. SIEM ingestion endpoint / Microsoft Teams Incoming Webhook). Common Alert Schema enabled. Empty = skip.')
@secure()
param siemWebhookUrl string = ''

@description('Resource tags.')
param tags object = {}

resource ag 'Microsoft.Insights/actionGroups@2023-09-01-preview' = {
  name: name
  location: 'global'
  tags: tags
  properties: {
    groupShortName: 'amlabAG'
    enabled: true
    emailReceivers: empty(email) ? [] : [
      {
        name: 'demo-owner'
        emailAddress: email
        useCommonAlertSchema: true
      }
    ]
    webhookReceivers: concat(
      empty(webhookUrl) ? [] : [
        {
          name: 'automitigation-logicapp'
          serviceUri: webhookUrl
          useCommonAlertSchema: true
        }
      ],
      empty(siemWebhookUrl) ? [] : [
        {
          name: 'siem-forward'
          serviceUri: siemWebhookUrl
          useCommonAlertSchema: true
        }
      ]
    )
  }
}

output id string = ag.id
output name string = ag.name
