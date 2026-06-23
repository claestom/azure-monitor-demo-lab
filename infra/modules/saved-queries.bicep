// =====================================================================================
// Saved KQL queries on the central LAW (and a couple cross-workspace examples).
// These appear under "Logs > Saved searches" in the workspace.
// =====================================================================================

@description('Central LAW name.')
param centralLawName string

@description('App Insights LAW name (used in cross-workspace queries).')
param appInsightsLawName string

resource centralLaw 'Microsoft.OperationalInsights/workspaces@2023-09-01' existing = {
  name: centralLawName
}

var category = 'AzureMonitorDemoLab'

var queries = [
  {
    name: 'vminsights-cpu-top10'
    displayName: '01 — VM Insights · Top 10 VMs by CPU (last 1h)'
    query: '// Top 10 VMs ranked by average CPU utilization over the last hour.\n// Source: VM Insights "InsightsMetrics" table (Azure Monitor Agent + VM Insights DCR).\n// Use for: quickly spotting hot VMs.\nInsightsMetrics\n| where TimeGenerated > ago(1h)\n| where Namespace == "Processor" and Name == "UtilizationPercentage"\n| summarize CpuPct = avg(Val) by Computer\n| top 10 by CpuPct desc'
  }
  {
    name: 'vminsights-memory'
    displayName: '02 — VM Insights · Available memory % per VM (last 1h)'
    query: '// Available memory (MB) per VM over the last hour, bucketed in 5-minute bins.\n// Source: VM Insights "InsightsMetrics".\n// Use for: spotting memory pressure trends and saw-tooth patterns.\nInsightsMetrics\n| where TimeGenerated > ago(1h)\n| where Namespace == "Memory" and Name == "AvailableMB"\n| summarize avg(Val) by Computer, bin(TimeGenerated, 5m)\n| render timechart'
  }
  {
    name: 'vm-heartbeat'
    displayName: '03 — VM Heartbeat · which VMs are alive?'
    query: '// Last heartbeat per VM with "minutes since" — useful liveness check.\n// Source: "Heartbeat" table, written by AMA on every VM.\n// Use for: detecting stopped / unreachable VMs (anything > 5 min is suspicious).\nHeartbeat\n| summarize LastHeartbeat = max(TimeGenerated) by Computer, OSType\n| extend MinutesSince = datetime_diff("minute", now(), LastHeartbeat)\n| order by MinutesSince desc'
  }
  {
    name: 'aks-pod-restarts'
    displayName: '04 — AKS · Pod restarts in last 24h'
    query: '// Total container restarts per pod over the last 24 hours.\n// Source: Container Insights "KubePodInventory".\n// Use for: catching crashloops and unstable workloads.\nKubePodInventory\n| where TimeGenerated > ago(24h)\n| summarize Restarts = sum(toint(ContainerRestartCount)) by Namespace, ControllerName, Name\n| where Restarts > 0\n| order by Restarts desc'
  }
  {
    name: 'aks-container-logs-errors'
    displayName: '05 — AKS · Container log errors (last 1h)'
    query: '// stdout/stderr lines from any AKS container that contain error-like keywords.\n// Source: Container Insights "ContainerLogV2" (new high-perf log table).\n// Use for: triaging app-level errors without kubectl logs.\nContainerLogV2\n| where TimeGenerated > ago(1h)\n| where LogMessage has_any ("error","exception","fatal","panic")\n| project TimeGenerated, Computer, PodName, ContainerName, LogMessage\n| order by TimeGenerated desc\n| take 100'
  }
  {
    name: 'aks-node-cpu-mem'
    displayName: '06 — AKS · Node CPU & Memory (last 1h)'
    query: '// AKS node-level CPU and memory perf counters over the last hour.\n// Source: Container Insights "Perf" table (cluster-level counters).\n// Use for: correlating noisy-neighbor workloads with node pressure.\nPerf\n| where TimeGenerated > ago(1h)\n| where ObjectName in ("K8SNode","Memory","Processor")\n| where CounterName in ("cpuUsageNanoCores","memoryWorkingSetBytes","% Processor Time")\n| summarize avg(CounterValue) by Computer, CounterName, bin(TimeGenerated, 5m)\n| render timechart'
  }
  {
    name: 'webapp-http-codes'
    displayName: '07 — App Service · HTTP status code distribution (last 1h)'
    query: '// Stacked column chart of HTTP status codes returned by App Services in this RG.\n// Source: "AppServiceHTTPLogs" diagnostic logs (sent to LAW via policy).\n// Use for: visualising 2xx/4xx/5xx mix during incidents or load tests.\nAppServiceHTTPLogs\n| where TimeGenerated > ago(1h)\n| summarize Hits = count() by ScStatus, bin(TimeGenerated, 5m)\n| render columnchart'
  }
  {
    name: 'webapp-slow-requests'
    displayName: '08 — App Service · Slowest requests (last 1h)'
    query: '// Top 50 slowest App Service requests in the last hour by TimeTaken (ms).\n// Source: "AppServiceHTTPLogs".\n// Use for: latency hunting before drilling into App Insights traces.\nAppServiceHTTPLogs\n| where TimeGenerated > ago(1h)\n| project TimeGenerated, CsHost, CsUriStem, ScStatus, TimeTaken\n| top 50 by TimeTaken desc'
  }
  {
    name: 'activity-changes'
    displayName: '09 — Activity log · Who changed what in this RG (last 24h)'
    query: '// Recent successful write/delete/action operations against resources in this RG.\n// Source: "AzureActivity" (subscription activity log streamed to LAW).\n// Use for: change-correlation during incident response ("what changed before this broke?").\nAzureActivity\n| where TimeGenerated > ago(24h)\n| where OperationNameValue has_any ("write","delete","action")\n| where ActivityStatusValue == "Success"\n| project TimeGenerated, Caller, OperationNameValue, ResourceProviderValue, _ResourceId\n| order by TimeGenerated desc'
  }
  {
    name: 'cross-ws-failed-vs-cpu'
    displayName: '10 — CROSS-WS · App Insights failed requests vs central LAW VM CPU (normalized 0–100)'
    query: '// CROSS-WORKSPACE: correlate App Insights failed-request count with VM CPU%.\n// Sources: workspace("${appInsightsLawName}").AppRequests  +  central LAW InsightsMetrics.\n// Both series are normalised to 0–100 (% of their own peak) so they fit one Y-axis.\n// Use for: cross-team incident review (devs + ops on one chart).\nlet appiFailed = workspace("${appInsightsLawName}").AppRequests\n  | where TimeGenerated > ago(1h) and Success == false\n  | summarize Failed = todouble(count()) by bin(TimeGenerated, 5m);\nlet vmCpu = InsightsMetrics\n  | where TimeGenerated > ago(1h)\n  | where Namespace == "Processor" and Name == "UtilizationPercentage"\n  | summarize CpuPct = todouble(avg(Val)) by bin(TimeGenerated, 5m);\nlet joined = appiFailed\n  | join kind=fullouter vmCpu on TimeGenerated\n  | project TimeGenerated = coalesce(TimeGenerated, TimeGenerated1),\n            Failed = coalesce(Failed, todouble(0)),\n            CpuPct = coalesce(CpuPct, todouble(0));\nlet maxFailed = toscalar(joined | summarize max(Failed));\nlet maxCpu    = toscalar(joined | summarize max(CpuPct));\njoined\n| extend FailedNorm = iff(maxFailed > 0, 100.0 * Failed / maxFailed, todouble(0)),\n         CpuNorm    = iff(maxCpu    > 0, 100.0 * CpuPct    / maxCpu,    todouble(0))\n| project TimeGenerated,\n          ["Failed requests (% of peak)"] = FailedNorm,\n          ["VM CPU (% of peak)"]          = CpuNorm\n| order by TimeGenerated asc\n| render timechart with (ytitle="% of peak")'
  }
  {
    name: 'cross-ws-end-to-end'
    displayName: '11 — CROSS-WS · End-to-end story (HTTP → AppI request → AKS pod logs)'
    query: '// CROSS-WORKSPACE: unify three signals into one chronological feed:\n//   1) App Service HTTP layer  (AppServiceHTTPLogs in this LAW)\n//   2) App Insights request    (AppRequests in the AppI LAW via workspace())\n//   3) AKS load-gen pod logs   (ContainerLogV2 in this LAW)\n// Use for: storytelling during a demo or post-mortem — show the same event from 3 angles.\nunion\n  (AppServiceHTTPLogs | where TimeGenerated > ago(1h) | project TimeGenerated, Source = "AppServiceHTTPLogs", Detail = strcat(CsMethod, " ", CsUriStem, " -> ", ScStatus)),\n  (workspace("${appInsightsLawName}").AppRequests | where TimeGenerated > ago(1h) | project TimeGenerated, Source = "AppI.AppRequests", Detail = strcat(Name, " | success=", Success, " | duration_ms=", DurationMs)),\n  (ContainerLogV2 | where TimeGenerated > ago(1h) | where PodName has "loadgen" | project TimeGenerated, Source = "AKS.ContainerLogV2", Detail = LogMessage)\n| order by TimeGenerated desc\n| take 200'
  }
  {
    name: 'appi-failures-by-operation'
    displayName: '12 — CROSS-WS · App Insights failures grouped by operation'
    query: '// CROSS-WORKSPACE: which App Insights operations are failing and how slow are they?\n// Source: workspace("${appInsightsLawName}").AppRequests.\n// Use for: a 10-second view of "which endpoints to fix first".\nworkspace("${appInsightsLawName}").AppRequests\n| where TimeGenerated > ago(1h)\n| where Success == false\n| summarize Failures = count(), AvgDurationMs = avg(DurationMs) by Name\n| order by Failures desc'
  }
  {
    name: 'cost-ingestion-per-table'
    displayName: '13 — Cost · Daily ingestion (GB) per table (last 7d)'
    query: '// Ingestion volume in GB per table for the last 7 days.\n// Source: "Usage" — built-in billing-meter table in every LAW.\n// Use for: cost reviews, picking candidates for DCR transformations or Basic Logs.\nUsage\n| where TimeGenerated > ago(7d)\n| where IsBillable == true\n| summarize GB = sum(Quantity) / 1024 by DataType, bin(TimeGenerated, 1d)\n| order by TimeGenerated desc, GB desc\n| render columnchart kind=stacked'
  }
  {
    name: 'cost-transformation-effect'
    displayName: '14 — Cost · Workspace Transformation effect on AzureActivity (proof)'
    query: '// Proves the FEATURE 1 workspace transformation on AzureActivity.\n// The DCR (dcr-amlab-workspace-transforms) does TWO things to every row:\n//   (a) FILTER:  drops "/read" operations (Get / List / Read)   <- saves $$ at ingest.\n//   (b) ENRICH:  adds a "FilteredBy" key to the dynamic Properties column.\n//\n// EXPECTED RESULT (single row), after the transform has been active for >= 1 min:\n//   RowsTotal                = the number of AzureActivity rows in last 1h\n//   RowsWithReadOperation    = 0     (filter dropped them at ingest)\n//   RowsWithFilteredBy       = RowsTotal  (the enrich marker is on EVERY kept row)\n//   DistinctOperations       = a short list of non-/read operations\nAzureActivity\n| where TimeGenerated > ago(1h)\n| extend FilteredBy = tostring(parse_json(Properties).FilteredBy)\n| summarize\n    RowsTotal             = count(),\n    RowsWithReadOperation = countif(tolower(OperationNameValue) endswith "/read"),\n    RowsWithFilteredBy    = countif(FilteredBy == "amlab-workspace-transform"),\n    DistinctOperations    = strcat_array(make_set(OperationNameValue, 10), ", ")'
  }
  {
    name: 'cost-transformation-sample'
    displayName: '15 — Cost · Workspace Transformation sample rows (AzureActivity)'
    query: '// 20 most recent AzureActivity rows showing the FEATURE 1 transform in action.\n// You should see EVERY row with:\n//   - OperationNameValue does NOT end with "/read"    (filter passed)\n//   - Properties.FilteredBy == "amlab-workspace-transform"  (enrich ran)\n//   - Properties.FilteredAt is a recent timestamp     (enrich ran, second prop)\nAzureActivity\n| where TimeGenerated > ago(1h)\n| extend FilteredBy = tostring(parse_json(Properties).FilteredBy),\n         FilteredAt = tostring(parse_json(Properties).FilteredAt)\n| project TimeGenerated, Caller, OperationNameValue, ActivityStatusValue, FilteredBy, FilteredAt\n| order by TimeGenerated desc\n| take 20'
  }
  {
    name: 'custom-logs-security-audit'
    displayName: '16 — Custom Logs · SecurityAudit_CL events (last 1h)'
    query: '// Custom log data sent via the Logs Ingestion API (scripts/send-custom-logs.ps1).\n// Source: "SecurityAudit_CL" — a custom table in this workspace.\n// Use for: proving external systems can push data into Log Analytics.\nSecurityAudit_CL\n| where TimeGenerated > ago(1h)\n| project TimeGenerated, EventType, Severity, UserPrincipal, SourceIP, Action, Result, Details\n| order by TimeGenerated desc'
  }
  {
    name: 'custom-logs-summary'
    displayName: '17 — Custom Logs · Security event breakdown'
    query: '// Aggregated view of custom security audit events by type and severity.\n// Source: "SecurityAudit_CL".\n// Use for: showing KQL analytics on custom ingested data.\nSecurityAudit_CL\n| where TimeGenerated > ago(24h)\n| summarize EventCount = count(), DistinctUsers = dcount(UserPrincipal) by EventType, Severity\n| order by EventCount desc'
  }
  {
    name: 'summary-rule-comparison'
    displayName: '18 — Cost · Summary Rule: raw Perf vs aggregated Perf_Hourly_CL'
    query: '// Compare raw Perf data volume vs the pre-aggregated Perf_Hourly_CL summary.\n// Shows the cost win: same answer from orders-of-magnitude fewer rows.\n// Source: "Perf" (raw) + "Perf_Hourly_CL" (summary).\nlet rawStats = Perf\n  | where TimeGenerated > ago(24h)\n  | where ObjectName in ("Processor","Memory","LogicalDisk")\n  | summarize RawRowCount = count(), RawDistinctComputers = dcount(Computer);\nlet summaryStats = Perf_Hourly_CL\n  | where TimeGenerated > ago(24h)\n  | summarize SummaryRowCount = count(), SummaryDistinctComputers = dcount(Computer);\nrawStats | extend placeholder = 1\n| join kind=inner (summaryStats | extend placeholder = 1) on placeholder\n| project RawRowCount, SummaryRowCount,\n          CompressionRatio = strcat("1:", tolong(RawRowCount / max_of(SummaryRowCount, 1))),\n          RawDistinctComputers, SummaryDistinctComputers'
  }
  {
    name: 'kql-function-vmhealth'
    displayName: '19 — Functions · vmHealth() — call the saved function'
    query: '// Call the vmHealth() saved function to get traffic-light status for all VMs.\n// This function is defined in kql-functions.bicep and stored in the workspace.\n// Use for: showing reusable KQL abstractions.\nvmHealth()\n| order by case(Status == "Red", 0, Status == "Orange", 1, 2) asc'
  }
  {
    name: 'kql-function-envhealth'
    displayName: '20 — Functions · envHealth() — combined environment health'
    query: '// Call the envHealth() function for a combined traffic-light view across\n// VMs, AKS pods, and App Insights. Cross-workspace, single function call.\n// Use for: showing how functions compose and abstract complexity.\nenvHealth()'
  }
  {
    name: 'rbac-granular-proof'
    displayName: '21 — RBAC · Granular RBAC proof (ABAC conditions)'
    query: '// Granular RBAC demo: run this query to see SecurityAudit_CL events.\n// With full access: all rows visible (all severities).\n// With table-level ABAC: only SecurityAudit_CL is queryable.\n// With row-level ABAC (Severity==Critical): only Critical rows appear.\n// Use for: proving ABAC table/row-level filtering.\nSecurityAudit_CL\n| where TimeGenerated > ago(24h)\n| summarize EventCount = count() by Severity, EventType\n| order by Severity asc, EventType asc'
  }
  {
    name: 'availability-test-results'
    displayName: '22 — Availability · Global test results (last 1h)'
    query: replace('__APPI_LAW__', appInsightsLawName, '// Availability test results from 5 global locations.\n// Source: workspace("__APPI_LAW__").AppAvailabilityResults.\nworkspace("__APPI_LAW__").AppAvailabilityResults\n| where TimeGenerated > ago(1h)\n| summarize SuccessCount = countif(Success == 1),\n            FailCount = countif(Success == 0),\n            AvgDurationMs = avg(DurationMs)\n            by Name, Location\n| extend Status = iff(FailCount > 0, "FAIL", "PASS")\n| order by Name asc, Location asc')
  }
  {
    name: 'connection-monitor-results'
    displayName: '23 — Network · Connection Monitor results (VMs → App Service)'
    query: '// Hop-by-hop network health from each lab VM to the App Service HTTPS endpoint.\n// Source: "NWConnectionMonitorTestResult" — written by Network Watcher Connection Monitor.\n// Use for: spotting transient or geographic packet-loss / latency issues.\nNWConnectionMonitorTestResult\n| where TimeGenerated > ago(1h)\n| summarize ChecksFailedPct = round(100.0 * countif(TestResult != "Pass") / count(), 2),\n            AvgRttMs = round(avg(AvgRoundTripTimeMs), 1)\n          by SourceName, DestinationName, bin(TimeGenerated, 5m)\n| order by TimeGenerated desc, SourceName asc'
  }
  {
    name: 'traffic-analytics-top-talkers'
    displayName: '24 — Network · Traffic Analytics top-talkers (Flow Logs)'
    query: '// Top inbound/outbound IP conversations enriched by Traffic Analytics.\n// Source: "NTANetAnalytics" — VNet flow logs + Traffic Analytics geo/topology enrichment.\n// Use for: surfacing unexpected egress destinations or noisy chatty peers.\nNTANetAnalytics\n| where TimeGenerated > ago(1h)\n| where SubType == "FlowLog"\n| where FlowDirection in ("I", "O")\n| extend Direction = iff(FlowDirection == "I", "Inbound", "Outbound")\n| summarize Flows = count(), BytesSrcToDest = sum(BytesSrcToDest), BytesDestToSrc = sum(BytesDestToSrc)\n          by Direction, SrcIp, DestIp, L4Protocol\n| top 20 by Flows desc'
  }
  {
    name: 'kv-insights-operations'
    displayName: '25 — Key Vault · AuditEvent operations (last 1h)'
    query: '// Every key-vault data-plane operation (get/list/set) — the data behind Key Vault Insights.\n// Source: "AzureDiagnostics" with ResourceType KEYVAULTS.\n// Use for: tracking secret access, expiring credential rotation, suspicious activity.\nAzureDiagnostics\n| where ResourceType == "VAULTS" and Category == "AuditEvent"\n| where TimeGenerated > ago(1h)\n| summarize Calls = count() by OperationName, ResultType, identity_claim_appid_g, CallerIPAddress\n| order by Calls desc'
  }
  {
    name: 'storage-insights-transactions'
    displayName: '26 — Storage · Transactions per API (last 1h)'
    query: '// Storage Insights backing data: transaction counts + total request units per API.\n// Source: "AzureMetrics" with ResourceProvider MICROSOFT.STORAGE.\n// Use for: top APIs, throttling investigations, capacity trending.\nAzureMetrics\n| where ResourceProvider == "MICROSOFT.STORAGE"\n| where TimeGenerated > ago(1h)\n| where MetricName in ("Transactions", "SuccessE2ELatency", "Ingress", "Egress")\n| summarize Avg = avg(Average), Total = sum(Total) by MetricName, bin(TimeGenerated, 5m)\n| render timechart'
  }
  {
    name: 'custom-metrics-cart-value'
    displayName: '27 — Custom · App Insights amlab.cartValue metric (1h)'
    query: replace('__APPI_LAW__', appInsightsLawName, '// Custom metric emitted by the .NET app on /api/checkout.\n// Source: workspace("__APPI_LAW__").AppMetrics (the App Insights LAW).\n// Demonstrates "codeless + TrackMetric" coexistence: SDK pre-aggregates locally.\nworkspace("__APPI_LAW__").AppMetrics\n| where TimeGenerated > ago(1h)\n| where Name == "amlab.cartValue"\n| summarize Avg = avg(Sum / ItemCount), P95 = percentile(Sum / ItemCount, 95), Count = sum(ItemCount)\n          by bin(TimeGenerated, 5m)\n| render timechart')
  }
  {
    name: 'custom-events-checkouts'
    displayName: '28 — Custom · CheckoutCompleted events (1h)'
    query: replace('__APPI_LAW__', appInsightsLawName, '// Custom event from /api/checkout — payment ok vs declined breakdown.\n// Source: workspace("__APPI_LAW__").AppEvents (the App Insights LAW).\nworkspace("__APPI_LAW__").AppEvents\n| where TimeGenerated > ago(1h)\n| where Name == "CheckoutCompleted"\n| extend paymentResult = tostring(parse_json(Properties).paymentResult)\n| summarize Count = count() by paymentResult, bin(TimeGenerated, 5m)\n| render columnchart kind=stacked')
  }
  {
    name: 'sentinel-incidents'
    displayName: '29 — Sentinel · Recent incidents (24h)'
    query: '// Sentinel incidents raised in the last 24h. Empty if Sentinel was disabled at deploy.\n// Source: "SecurityIncident" (Sentinel-managed table on the central LAW).\nSecurityIncident\n| where TimeGenerated > ago(24h)\n| project TimeGenerated, IncidentNumber, Title, Severity, Status, CreatedTime, ClassificationReason\n| order by TimeGenerated desc'
  }
  {
    name: 'connection-monitor-availability'
    displayName: '30 — Network · End-to-end availability over 24h'
    query: '// 1-hour buckets of connectivity availability per (source, destination) pair.\n// Source: "NWConnectionMonitorTestResult".\nNWConnectionMonitorTestResult\n| where TimeGenerated > ago(24h)\n| summarize\n      Passes = countif(TestResult == "Pass"),\n      Fails = countif(TestResult != "Pass"),\n      AvailabilityPct = round(100.0 * countif(TestResult == "Pass") / count(), 2)\n    by SourceName, DestinationName, bin(TimeGenerated, 1h)\n| render timechart'
  }
]

resource savedSearches 'Microsoft.OperationalInsights/workspaces/savedSearches@2020-08-01' = [for q in queries: {
  parent: centralLaw
  name: q.name
  properties: {
    category: category
    displayName: q.displayName
    query: q.query
    version: 2
  }
}]
