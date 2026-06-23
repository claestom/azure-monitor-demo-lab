// =====================================================================================
// Summary Rule — pre-aggregates high-volume Perf data into an hourly summary table.
// Demonstrates cost-efficient data retention: query the summary for dashboards,
// keep raw data on short retention or Basic Logs.
// =====================================================================================

@description('Central LAW name.')
param centralLawName string

@description('Central LAW resource ID (reserved for future use).')
#disable-next-line no-unused-params
param centralLawId string

@description('Region (reserved for future use).')
#disable-next-line no-unused-params
param location string

@description('Resource tags (reserved for future use).')
#disable-next-line no-unused-params
param tags object = {}

resource centralLaw 'Microsoft.OperationalInsights/workspaces@2023-09-01' existing = {
  name: centralLawName
}

// ---------------------------------------------------------------------------------
// Custom table: Perf_Hourly_CL — receives pre-aggregated rows
// ---------------------------------------------------------------------------------
resource summaryTable 'Microsoft.OperationalInsights/workspaces/tables@2022-10-01' = {
  parent: centralLaw
  name: 'Perf_Hourly_CL'
  properties: {
    plan: 'Analytics'
    schema: {
      name: 'Perf_Hourly_CL'
      columns: [
        { name: 'TimeGenerated', type: 'datetime', description: 'Hour bucket start' }
        { name: 'Computer', type: 'string', description: 'Source computer' }
        { name: 'CounterName', type: 'string', description: 'Performance counter name' }
        { name: 'AvgValue', type: 'real', description: 'Average value in the hour' }
        { name: 'MinValue', type: 'real', description: 'Minimum value in the hour' }
        { name: 'MaxValue', type: 'real', description: 'Maximum value in the hour' }
        // 'long' (not 'int') because the summary-rule workflow emits count() as
        // bigint; a column-type mismatch makes Microsoft.OperationalInsights/
        // summarylogs validation fail with UpsertTableFatalError.
        { name: 'SampleCount', type: 'long', description: 'Number of raw samples aggregated' }
      ]
    }
    retentionInDays: 180
  }
}

// ---------------------------------------------------------------------------------
// NOTE: The actual summary rule (rule-perf-hourly) is created via
//   scripts/create-summary-rule.ps1, which is invoked automatically from
//   scripts/post-deploy.ps1. The rule uses the GA REST API
//   (Microsoft.OperationalInsights/workspaces/summaryLogs, api-version 2025-07-01),
//   which is not yet exposed as a first-class Bicep type. The destination table
//   is created here so we can pin the 180-day retention and Analytics plan.
// ---------------------------------------------------------------------------------

output tableName string = summaryTable.name
