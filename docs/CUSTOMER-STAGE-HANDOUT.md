# Customer Handout - Stage Rollout Time and Cost

This one-pager helps customers decide how far to go in a workshop or pilot.

## Assumptions

- Region: Sweden Central
- Pricing basis: list price guidance from this lab's README
- Cost values are directional ranges, not quotes
- Monthly impact assumes resources are left running 24/7
- Stopping VMs/AKS between demos materially reduces cost

## Stage-by-stage estimate

| Stage | High-level scenario theme | Typical deployment time | Incremental monthly cost impact | Main cost drivers |
|---|---|---|---|---|
| Stage A - Foundation | Telemetry backbone, workspace and policy foundations (scenarios 1, 5, 6, 9 baseline) | 8-15 min | EUR 5-25 | Log ingestion, storage transactions, baseline monitor resources |
| Stage B - Workloads and dashboards | VM/AKS/App Service telemetry and dashboards (scenarios 2, 3, 4, 22, 28-32, 34-36, 42) | 20-35 min | EUR 95-145 | AKS node(s), two VMs, App Service plan, additional ingestion |
| Stage C - Alerts and response | Alerting, Action Group, auto-mitigation, processing rules (scenarios 7, 8, 12, 15, 17, 19, 23, 37) | 5-12 min | EUR 0-10 | Alert evaluations, action executions, extra logs from tests |
| Stage D - Security posture | Monitor-native detections for drift, IAM changes, exfil signals (scenarios 27, 47, 48, 49) | 5-12 min | EUR 0-15 | AzureActivity ingestion and scheduled query alerts |
| Stage E - Optional advanced add-ons | Sentinel/reliability/archival extras (scenarios 43, 44, 45, 46) | 10-20 min | EUR 0-40 | Sentinel analytics usage, archive/restore/search workloads, preview feature telemetry |

## Cumulative monthly range by stop point

| Stop after stage | Expected monthly range |
|---|---|
| Stage A | EUR 5-25 |
| Stage B | EUR 100-170 |
| Stage C | EUR 100-180 |
| Stage D | EUR 105-195 |
| Stage E | EUR 105-235 |

## Practical guidance for customer conversations

1. Start with Stage A + B for technical proof of value.
2. Add Stage C when on-call and response workflow are in scope.
3. Add Stage D for security posture outcomes without requiring SIEM.
4. Add Stage E only when customer explicitly wants Sentinel/reliability-preview and accepts extra complexity.

## Cost optimization notes

1. Stop AKS and deallocate VMs outside workshop windows.
2. Keep LAW caps and table plans under review.
3. Use staged rollout so customers only pay for scenarios they are currently validating.
