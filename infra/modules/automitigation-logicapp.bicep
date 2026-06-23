// =====================================================================================
// FEATURE 5 — Auto-mitigation Logic App
//
// Consumption-tier Logic App with a system-assigned managed identity.
//
// Trigger:  HTTP webhook (Common Alert Schema). Wired to the existing Action Group
//           via a webhook receiver (see actiongroup.bicep).
// Workflow:
//   1. Parse the inbound alert (Common Alert Schema).
//   2. If alertTargetIDs[0] is a VM → call ARM `restart` on it.
//   3. Otherwise → no-op (logs the payload).
//
// Identity: System-assigned. Granted **Contributor** at RG scope so it can call
//           Microsoft.Compute/virtualMachines/restart/action.
//
// NOTE: in production you'd narrow this to Virtual Machine Contributor.
// =====================================================================================

@description('Logic App name.')
param name string

@description('Region.')
param location string

@description('Resource tags.')
param tags object = {}

// ---------------------------------------------------------------------------------
// Logic App workflow (Consumption)
// ---------------------------------------------------------------------------------
resource logic 'Microsoft.Logic/workflows@2019-05-01' = {
  name: name
  location: location
  tags: tags
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    state: 'Enabled'
    definition: {
      '$schema': 'https://schema.management.azure.com/providers/Microsoft.Logic/schemas/2016-06-01/workflowdefinition.json#'
      contentVersion: '1.0.0.0'
      parameters: {}
      triggers: {
        manual: {
          type: 'Request'
          kind: 'Http'
          inputs: {
            schema: {
              type: 'object'
              properties: {
                schemaId: { type: 'string' }
                data: {
                  type: 'object'
                  properties: {
                    essentials: {
                      type: 'object'
                      properties: {
                        alertId: { type: 'string' }
                        alertRule: { type: 'string' }
                        severity: { type: 'string' }
                        signalType: { type: 'string' }
                        monitorCondition: { type: 'string' }
                        alertTargetIDs: { type: 'array' }
                      }
                    }
                  }
                }
              }
            }
          }
        }
      }
      actions: {
        Parse_target: {
          type: 'Compose'
          inputs: '@first(triggerBody()?[\'data\']?[\'essentials\']?[\'alertTargetIDs\'])'
          runAfter: {}
        }
        Is_VM: {
          type: 'If'
          expression: {
            and: [
              {
                contains: [
                  '@toLower(outputs(\'Parse_target\'))'
                  'microsoft.compute/virtualmachines'
                ]
              }
              {
                equals: [
                  '@toLower(triggerBody()?[\'data\']?[\'essentials\']?[\'monitorCondition\'])'
                  'fired'
                ]
              }
            ]
          }
          runAfter: {
            Parse_target: [ 'Succeeded' ]
          }
          actions: {
            Start_VM: {
              type: 'Http'
              inputs: {
                // /start works for BOTH cases:
                //   - VM is deallocated  → it starts up
                //   - VM is already running → returns 409 Conflict (we ignore, see runAfter on Respond)
                // /restart would fail on a deallocated VM (the most common demo "break") so we don't use it.
                method: 'POST'
                uri: '@{concat(\'https://management.azure.com\', outputs(\'Parse_target\'), \'/start?api-version=2024-03-01\')}'
                authentication: {
                  type: 'ManagedServiceIdentity'
                  audience: 'https://management.azure.com'
                }
              }
            }
          }
          else: {
            actions: {
              Log_no_op: {
                type: 'Compose'
                inputs: 'No matching mitigation action for this alert.'
              }
            }
          }
        }
        Respond: {
          type: 'Response'
          kind: 'Http'
          inputs: {
            statusCode: 200
            body: {
              message: 'Auto-mitigation Logic App processed the alert.'
              target: '@outputs(\'Parse_target\')'
              fired: '@triggerBody()?[\'data\']?[\'essentials\']?[\'monitorCondition\']'
            }
          }
          runAfter: {
            Is_VM: [ 'Succeeded', 'Skipped', 'Failed' ]
          }
        }
      }
    }
  }
}

// Grant the Logic App's MSI Contributor at RG scope so it can restart VMs.
// (Role ID: b24988ac-6180-42a0-ab88-20f7382dd24c = Contributor)
resource roleAssign 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(resourceGroup().id, logic.id, 'rg-contributor')
  properties: {
    principalId: logic.identity.principalId
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'b24988ac-6180-42a0-ab88-20f7382dd24c')
    principalType: 'ServicePrincipal'
  }
}

// Expose the trigger URL with SAS so the Action Group can call it.
output id string = logic.id
output name string = logic.name
output callbackUrl string = listCallbackURL('${logic.id}/triggers/manual', '2019-05-01').value
