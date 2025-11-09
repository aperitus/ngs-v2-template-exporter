# NGS v2 – Template Exporter (v2.0.0)

**Goal:** Export live Azure network state into **subscription‑scope deployable ARM templates** that the Net Guard Deployment Stack can consume with guard rails.

Works with: Bash + Azure CLI + jq (no Terraform required for export).  
Outputs: `main.subscription.json` + `rg-*.network.json` + `report.json`

## Features (v2.0.0)
- Discovers VNets, Subnets, Route Tables (+ routes), NSGs (+ rules) across one or more RGs.
- Builds **per‑RG** ARM templates (RG‑scoped) with required `location` and normalized shapes.
- Emits a **subscription‑scope wrapper** that nests each RG template via inline `template`.
- Uses **fully‑qualified** cross‑RG IDs for Subnet→UDR and Subnet→NSG associations.
- Enforces **single** `addressPrefix` on subnets (first prefix by default; or **fail** via flag).
- Deterministic ordering; JSON is pretty‑printed and stable.
- Logging and `--debug` for deep diagnostics.
- Report (`report.json`) summarizing discovered items and normalizations.

## Requirements
- **Azure CLI** (logged in; Reader or above)  
- **jq** 1.6+  
- Bash 4+

## Quick Start
```bash
# 1) Ensure az login and correct subscription context
az account set --subscription "<SUB_ID>"

# 2) Run exporter
./exporter/ngs-template-exporter.sh   --subscription-id "<SUB_ID>"   --rg rg-demo-core-uks-01   --rg rg-demo-sec-uks-01   --outdir ./out   --normalize-address-prefix first   --log-level info

# 3) Inspect outputs
tree ./out
# ./out
# ├─ main.subscription.json
# ├─ rg-rg-demo-core-uks-01.network.json
# ├─ rg-rg-demo-sec-uks-01.network.json
# └─ report.json
```

## CLI
```
ngs-template-exporter.sh
  --subscription-id <id>            (required)
  [--rg <name>]...                  One or more RGs. If omitted, scans entire subscription.
  [--region-filter <regex>]         Include only resources in regions matching regex.
  [--include natgw]                 (placeholder) Discover NAT Gateways (not emitted in v2.0.0).
  [--outdir <path>]                 Output directory (default: ./out)
  [--normalize-address-prefix first|fail]  Default: first
  [--format arm]                    Only 'arm' supported in v2.0.0
  [--log-level info|debug]          Default: info
  [--debug]                         Alias for --log-level debug
  [-h|--help]
```

## Output Contract
- **Subscription wrapper** (`main.subscription.json`):  
  - `$schema`: 2019‑04‑01 template schema  
  - Contains one `Microsoft.Resources/deployments` per RG (`Incremental`, `expressionEvaluationOptions.scope: inner`) with the RG‑scoped template inlined as `template`.
  - _Cross‑RG deploy ordering_: basic heuristic sets `dependsOn` where a subnet references a UDR/NSG in another RG. (See **Limitations**.)

- **Per‑RG template** (`rg-<rg>.network.json`):
  - Declares VNets (with `location`), Route Tables (+ routes), NSGs (+ rules), and Subnets (with **single** `addressPrefix`).  
  - Subnet associations (to UDR/NSG) use **fully‑qualified** `resourceId(subscription().subscriptionId,'<rg>','<type>','<name>')`.

- **Report** (`report.json`):
  - Counts, lists, normalization decisions (e.g., which subnets truncated multiple prefixes), and cross‑RG edges.

## Limitations (to be addressed in 2.1.x)
- **Cross‑RG dependsOn** uses a heuristic (parses discovered associations) and may be conservative. If ordering is insufficient on first deploy, re‑apply or split runs by RG to prime producers before consumers.
- `addressPrefixes` with multiple entries are truncated to the first unless `--normalize-address-prefix fail` is set.
- NAT Gateway discovery is logged (when `--include natgw`) but **not** yet emitted to templates.
- Only ARM JSON output; Bicep planned for v2.1.x.

## Logging & Debugging
- `--log-level debug` (or `--debug`) prints executed `az` commands and raw payload sizes.
- All decisions are echoed with `INFO` lines; `DEBUG` shows parsed fragments (resource names, RGs, counts).

## Versioning
- Semantic versioning: **major.minor.build**, starting at **2.0.0** for NGS v2.
- Version stored in `exporter/version.txt` and echoed into `main.subscription.json` metadata (`x-ngs-version`).

## Alignment with Net Guard Deployment Stack
- Subscription‑scope wrapper
- RG nested deployments specify `resourceGroup` without `location`
- VNets/UDRs/NSGs carry `location`
- **Subnets use `addressPrefix` (singular)**
- Subnet→UDR association uses fully‑qualified IDs
- Optional Day‑2 flags kept as‑is if present on source subnets:
  - `privateEndpointNetworkPolicies`, `privateLinkServiceNetworkPolicies`, `serviceEndpoints`

## Example: Generate from entire subscription
```bash
./exporter/ngs-template-exporter.sh   --subscription-id "<SUB_ID>"   --outdir ./out-all --log-level info
```

---

© 2025-11-09 Net Guard Deployment Stack v2 — Template Exporter
