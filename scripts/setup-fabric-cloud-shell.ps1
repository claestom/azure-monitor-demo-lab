<#
.SYNOPSIS
  Run Microsoft Fabric setup from Azure Cloud Shell.
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory)] [string] $SubscriptionId,
  [Parameter(Mandatory)] [string] $ResourceGroup,
  [string] $NamePrefix = 'amlab',
  [string] $WorkspaceName = 'Azure Monitor Demo Lab',
  [ValidateRange(5, 120)] [int] $MaxOperationMinutes = 30,
  [switch] $SkipEventstreamConnection
)

$ErrorActionPreference = 'Stop'
$setupParameters = @{
  SubscriptionId = $SubscriptionId
  ResourceGroup = $ResourceGroup
  NamePrefix = $NamePrefix
  WorkspaceName = $WorkspaceName
  MaxOperationMinutes = $MaxOperationMinutes
}
if ($SkipEventstreamConnection) {
  $setupParameters.SkipEventstreamConnection = $true
}

& (Join-Path $PSScriptRoot 'setup-fabric.ps1') @setupParameters