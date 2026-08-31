<#
.SYNOPSIS
  Run Microsoft Fabric setup from Azure Cloud Shell.
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory)] [string] $SubscriptionId,
  [Parameter(Mandatory)] [string] $ResourceGroup,
  [string] $NamePrefix = 'amlab',
  [string] $WorkspaceName = 'Azure Monitor Demo Lab'
)

$ErrorActionPreference = 'Stop'
& (Join-Path $PSScriptRoot 'setup-fabric.ps1') `
  -SubscriptionId $SubscriptionId `
  -ResourceGroup $ResourceGroup `
  -NamePrefix $NamePrefix `
  -WorkspaceName $WorkspaceName