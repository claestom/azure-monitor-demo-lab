# Resource group: external (BYO). The user (or a wrapper script / pipeline) is
# responsible for creating the RG before running terraform apply. Terraform
# only LOOKS IT UP via data source so it can hand each stage a parent_id.
# Benefit: `terraform destroy` removes only the resources inside the RG, leaving
# the RG (and anything else the user put in it) intact. This matches the BYO-RG
# intent and avoids count-flipping / state-ownership issues of create-if-missing.
#
# Create the RG first (idempotent):
#   az group create -n <resource_group_name> -l <location>
data "azurerm_resource_group" "lab" {
  name = var.resource_group_name
}

resource "azapi_resource" "stage_a" {
  count     = var.enable_stage_a ? 1 : 0
  type      = "Microsoft.Resources/deployments@2022-09-01"
  name      = "stage-a-foundation"
  parent_id = data.azurerm_resource_group.lab.id

  body = {
    properties = {
      mode     = "Incremental"
      template = sensitive(jsondecode(file("${path.module}/../infra/stages/00-foundation.json")))
      parameters = {
        location               = { value = var.location }
        namePrefix             = { value = var.name_prefix }
        dailyCapGb             = { value = var.daily_cap_gb }
        ownerTag               = { value = var.owner_tag }
        enableLawReplication   = { value = var.enable_law_replication }
        lawReplicationLocation = { value = var.law_replication_location }
      }
    }
  }
}

resource "azapi_resource" "stage_b" {
  count     = var.enable_stage_b ? 1 : 0
  type      = "Microsoft.Resources/deployments@2022-09-01"
  name      = "stage-b-workloads"
  parent_id = data.azurerm_resource_group.lab.id

  # Stage B references Stage A's LAW via 'existing' — wait for A to finish.
  depends_on = [azapi_resource.stage_a]

  body = {
    properties = {
      mode     = "Incremental"
      template = sensitive(jsondecode(file("${path.module}/../infra/stages/10-workloads.json")))
      parameters = {
        location        = { value = var.location }
        namePrefix      = { value = var.name_prefix }
        vmAdminUsername = { value = var.vm_admin_username }
        vmAdminPassword = { value = var.vm_admin_password }
        deployWindowsVm = { value = var.deploy_windows_vm }
        deployLinuxVm   = { value = var.deploy_linux_vm }
        vmSize          = { value = var.vm_size }
        aksNodeVmSize   = { value = var.aks_node_vm_size }
        aksNodeCount    = { value = var.aks_node_count }
        ownerTag        = { value = var.owner_tag }
      }
    }
  }
}

resource "azapi_resource" "stage_c" {
  count     = var.enable_stage_c ? 1 : 0
  type      = "Microsoft.Resources/deployments@2022-09-01"
  name      = "stage-c-alerting"
  parent_id = data.azurerm_resource_group.lab.id

  # Stage C targets Stage B's VMs and Stage A's LAW — wait for both.
  depends_on = [azapi_resource.stage_a, azapi_resource.stage_b]

  body = {
    properties = {
      mode     = "Incremental"
      template = sensitive(jsondecode(file("${path.module}/../infra/stages/20-alerting.json")))
      parameters = {
        location        = { value = var.location }
        namePrefix      = { value = var.name_prefix }
        alertEmail      = { value = var.alert_email }
        siemWebhookUrl  = { value = var.siem_webhook_url }
        vmAdminUsername = { value = var.vm_admin_username }
        vmAdminPassword = { value = var.vm_admin_password }
        deployWindowsVm = { value = var.deploy_windows_vm }
        deployLinuxVm   = { value = var.deploy_linux_vm }
        ownerTag        = { value = var.owner_tag }
      }
    }
  }
}

resource "azapi_resource" "stage_d" {
  count     = var.enable_stage_d ? 1 : 0
  type      = "Microsoft.Resources/deployments@2022-09-01"
  name      = "stage-d-security-posture"
  parent_id = data.azurerm_resource_group.lab.id

  # Stage D references Stage A's LAW via 'existing' AND Stage C's Action Group
  # ('ag-${namePrefix}-email') as an alert target. Without depending on C, an
  # all-at-once apply races C and D in parallel and Azure rejects the alerts
  # with `BadRequest: Action Group ... is invalid`.
  depends_on = [azapi_resource.stage_a, azapi_resource.stage_c]

  body = {
    properties = {
      mode     = "Incremental"
      template = sensitive(jsondecode(file("${path.module}/../infra/stages/30-security-posture.json")))
      parameters = {
        location   = { value = var.location }
        namePrefix = { value = var.name_prefix }
        ownerTag   = { value = var.owner_tag }
      }
    }
  }
}

resource "azapi_resource" "stage_e" {
  count     = var.enable_stage_e ? 1 : 0
  type      = "Microsoft.Resources/deployments@2022-09-01"
  name      = "stage-e-optional-advanced"
  parent_id = data.azurerm_resource_group.lab.id

  # Stage E targets Stage A's LAW and Stage B's webapp/AKS, AND Stage C's
  # Action Group ('ag-${namePrefix}-email') as an alert target. Without depending
  # on C, an all-at-once apply races C and E in parallel and Azure rejects the
  # alerts with `BadRequest: Action Group ... is invalid`.
  depends_on = [azapi_resource.stage_a, azapi_resource.stage_b, azapi_resource.stage_c]

  body = {
    properties = {
      mode     = "Incremental"
      template = sensitive(jsondecode(file("${path.module}/../infra/stages/40-optional-advanced.json")))
      parameters = {
        location        = { value = var.location }
        namePrefix      = { value = var.name_prefix }
        enableSentinel  = { value = var.enable_sentinel }
        deployWindowsVm = { value = var.deploy_windows_vm }
        deployLinuxVm   = { value = var.deploy_linux_vm }
        ownerTag        = { value = var.owner_tag }
      }
    }
  }
}
