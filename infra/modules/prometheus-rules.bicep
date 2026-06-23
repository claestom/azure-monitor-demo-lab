// =====================================================================================
// Managed Prometheus Rule Group
//
// Recording + alerting rules evaluated against the Azure Monitor Workspace (AMW)
// where AKS sends Prometheus metrics. Recording rules pre-compute expensive
// PromQL into a new time series. Alerting rules wire to the demo Action Group.
//
// Scope: the AMW (NOT the AKS cluster — that's a common mistake).
// =====================================================================================

@description('Rule group name.')
param name string

@description('Region (Prometheus rule groups must match AMW region).')
param location string

@description('Azure Monitor Workspace (AMW) resource ID — the rules query metrics here.')
param azureMonitorWorkspaceId string

@description('AKS cluster resource ID — populates the `clusterName` label for context.')
param aksClusterId string

@description('Action group ID for alert notifications.')
param actionGroupId string

@description('Resource tags.')
param tags object = {}

resource ruleGroup 'Microsoft.AlertsManagement/prometheusRuleGroups@2023-03-01' = {
  name: name
  location: location
  tags: tags
  properties: {
    description: 'Demo lab: recording + alerting rules on AKS Prometheus metrics.'
    enabled: true
    clusterName: last(split(aksClusterId, '/'))
    interval: 'PT1M'
    scopes: [ azureMonitorWorkspaceId ]
    rules: [
      // Recording rule: aggregate CPU usage per node — useful for dashboards & alerts.
      {
        record: 'amlab:node_cpu_seconds:rate5m'
        expression: 'sum by (instance) (rate(node_cpu_seconds_total{mode!="idle"}[5m]))'
        labels: {
          source: 'amlab'
        }
      }
      // Recording rule: container memory working set per namespace.
      {
        record: 'amlab:container_memory_working_set_bytes:sum'
        expression: 'sum by (namespace) (container_memory_working_set_bytes{container!=""})'
        labels: {
          source: 'amlab'
        }
      }
      // Alerting rule: pod is in CrashLoopBackOff for > 5 min.
      {
        alert: 'AmlabPodCrashLooping'
        expression: 'max_over_time(kube_pod_container_status_waiting_reason{reason="CrashLoopBackOff"}[5m]) > 0'
        for: 'PT5M'
        severity: 3
        labels: {
          team: 'demo-lab'
          severity: 'warning'
        }
        annotations: {
          summary: 'Pod {{ $labels.namespace }}/{{ $labels.pod }} is crashlooping'
          description: 'Container {{ $labels.container }} has been in CrashLoopBackOff for at least 5 minutes.'
        }
        resolveConfiguration: {
          autoResolved: true
          timeToResolve: 'PT10M'
        }
        actions: [
          { actionGroupId: actionGroupId }
        ]
      }
      // Alerting rule: node memory pressure (< 200 MiB free).
      {
        alert: 'AmlabNodeMemoryPressure'
        expression: 'node_memory_MemAvailable_bytes < 209715200'
        for: 'PT10M'
        severity: 2
        labels: {
          team: 'demo-lab'
        }
        annotations: {
          summary: 'AKS node {{ $labels.instance }} low memory'
          description: 'Available memory has been below 200 MiB for 10 minutes.'
        }
        resolveConfiguration: {
          autoResolved: true
          timeToResolve: 'PT15M'
        }
        actions: [
          { actionGroupId: actionGroupId }
        ]
      }
    ]
  }
}

output id string = ruleGroup.id
output name string = ruleGroup.name
