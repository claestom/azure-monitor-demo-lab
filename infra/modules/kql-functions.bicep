// =====================================================================================
// Reusable KQL functions stored in the central LAW.
// Callable from any query, workbook, or alert as a virtual table or function.
// =====================================================================================

@description('Central LAW name.')
param centralLawName string

@description('App Insights LAW name (for cross-workspace functions).')
param appInsightsLawName string

resource centralLaw 'Microsoft.OperationalInsights/workspaces@2023-09-01' existing = {
  name: centralLawName
}

var category = 'AzureMonitorDemoLab'

// ---------------------------------------------------------------------------------
// Function 1 — vmHealth(): traffic-light status for all VMs
//   Returns one row per VM with a colour code (Green/Orange/Red)
//   based on last heartbeat age + CPU.
// ---------------------------------------------------------------------------------
resource fnVmHealth 'Microsoft.OperationalInsights/workspaces/savedSearches@2020-08-01' = {
  parent: centralLaw
  name: 'fn-vmHealth'
  properties: {
    category: category
    displayName: 'Function: vmHealth() — traffic-light status for all VMs'
    functionAlias: 'vmHealth'
    functionParameters: ''
    query: '''let heartbeats = Heartbeat
  | summarize LastHB = max(TimeGenerated) by Computer, OSType
  | extend MinutesSinceHB = datetime_diff("minute", now(), LastHB);
let cpu = InsightsMetrics
  | where TimeGenerated > ago(15m)
  | where Namespace == "Processor" and Name == "UtilizationPercentage"
  | summarize AvgCpu = avg(Val) by Computer;
heartbeats
| join kind=leftouter cpu on Computer
| extend AvgCpu = coalesce(AvgCpu, 0.0)
| extend Status = case(
    MinutesSinceHB > 5 or AvgCpu > 90, "Red",
    MinutesSinceHB > 2 or AvgCpu > 70, "Orange",
    "Green")
| project Computer, OSType, LastHB, MinutesSinceHB, AvgCpu, Status'''
    version: 2
  }
}

// ---------------------------------------------------------------------------------
// Function 2 — aksHealth(): traffic-light status for AKS pods
// ---------------------------------------------------------------------------------
resource fnAksHealth 'Microsoft.OperationalInsights/workspaces/savedSearches@2020-08-01' = {
  parent: centralLaw
  name: 'fn-aksHealth'
  properties: {
    category: category
    displayName: 'Function: aksHealth() — traffic-light status for AKS pods'
    functionAlias: 'aksHealth'
    functionParameters: ''
    query: '''KubePodInventory
| where TimeGenerated > ago(15m)
| summarize Restarts = sum(toint(ContainerRestartCount)),
            arg_max(TimeGenerated, PodStatus) by Namespace, Name, ControllerName
| extend Status = case(
    PodStatus !in ("Running","Succeeded") or Restarts > 10, "Red",
    Restarts > 3, "Orange",
    "Green")
| project Namespace, Pod = Name, Controller = ControllerName, PodStatus, Restarts, Status'''
    version: 2
  }
}

// ---------------------------------------------------------------------------------
// Function 3 — envHealth(): combined environment health across all resources
//   Unions vmHealth() + aksHealth() + App Insights summary into one table.
// ---------------------------------------------------------------------------------
resource fnEnvHealth 'Microsoft.OperationalInsights/workspaces/savedSearches@2020-08-01' = {
  parent: centralLaw
  name: 'fn-envHealth'
  properties: {
    category: category
    displayName: 'Function: envHealth() — combined environment health'
    functionAlias: 'envHealth'
    functionParameters: ''
    query: replace('__APPI_LAW__', appInsightsLawName, '''let vms = vmHealth()
  | project ResourceType = "VM", ResourceName = Computer, Status, Detail = strcat("CPU=", round(AvgCpu,1), "% HB=", MinutesSinceHB, "m ago");
let pods = aksHealth()
  | project ResourceType = "AKS Pod", ResourceName = Pod, Status, Detail = strcat("Restarts=", Restarts, " Status=", PodStatus);
let appi = workspace("__APPI_LAW__").AppRequests
  | where TimeGenerated > ago(15m)
  | summarize Total = count(), Failed = countif(Success == false)
  | extend FailPct = round(100.0 * Failed / Total, 1)
  | extend Status = case(FailPct > 10, "Red", FailPct > 5, "Orange", "Green")
  | project ResourceType = "App Insights", ResourceName = "App Service", Status, Detail = strcat("FailRate=", FailPct, "% (", Failed, "/", Total, ")");
union vms, pods, appi
| order by case(Status == "Red", 0, Status == "Orange", 1, 2) asc, ResourceType asc''')
    version: 2
  }
}
