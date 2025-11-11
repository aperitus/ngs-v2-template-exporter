# NGS v2 – Template Exporter
**Version:** 2.0.25  
**Purpose:** Export *safe-to-reapply* ARM JSON for Azure network guard rails (VNets, subnets, NSGs, route tables, NAT GW, VNet GW, public IPs/prefixes, VNet peerings) that can be deployed **as one subscription-scope template** by the **Stack Deployer (NGS v2 – Deployment Stack Wrapper) v2.1.2**.

---

## BLUF
- Generates one **subscription-scope wrapper** with **per‑RG nested deployments** (RG‑scoped, no `location` on the nested resource).
- **Never emits empty arrays or nulls** for properties that would **clear** settings (e.g., subnet delegations/endpoints).
- **Preserves tags** for supported resources by default (toggle with `--no-tags`).  
- Adds **cross‑RG `dependsOn`** for VNet peerings & gateway/NAT public IPs so the wrapper applies cleanly.
- Compatible with **az CLI ≥ 2.40.0** and **jq ≥ 1.6** (must support `--argfile`).

---

## Features
- **Resources captured**
  - `Microsoft.Network/virtualNetworks` (+ `subnets` with safe emission rules)
  - `Microsoft.Network/networkSecurityGroups`
  - `Microsoft.Network/routeTables`
  - `Microsoft.Network/natGateways` (+ referenced `publicIPAddresses`/`publicIPPrefixes`)
  - `Microsoft.Network/virtualNetworkGateways` (+ referenced `publicIPAddresses`)
  - **Optional**: `Microsoft.Network/virtualNetworks/virtualNetworkPeerings` (on; can disable)
- **Wrapper orchestration**
  - One file: `main.subscription.json` with nested `Microsoft.Resources/deployments` per RG
  - Adds **inter‑RG `dependsOn`** for: peerings, NAT GW PIPs/PIPPs, VNet GW PIPs
- **Safety**
  - Omit keys entirely if values are empty/unknown
  - Subnets: do **not** emit `serviceEndpoints: []`, `delegations: []`, or `*NetworkPolicies: null`
- **Tags**
  - Emitted by default for supported resources (VNets/NSGs/RTs/NAT GW/PIPs/PIPPs/VNet GW)
  - Toggle off via `--no-tags`
- **Diagnostics**
  - Preflight: version checks (**az**, **jq**, `jq --argfile` capability)
  - `--strict-safety`: fail if any dangerous empties/nulls are detected in subnet properties
  - `--dump-raw`: saves the Azure raw payloads per RG for auditing

---

## Version constraints (required)
- **azure-cli**: `>= 2.40.0` (tested up to 2.78.x)
- **jq**: `>= 1.6` **and** must support `--argfile`  
  The exporter validates both and exits with a clear error if incompatible.

---

## Installation
```bash
chmod +x exporter/ngs-template-exporter.sh
```

---

## Usage
### Export entire subscription
```bash
./exporter/ngs-template-exporter.sh   --subscription-id "00000000-0000-0000-0000-000000000000"   --outdir ./out   --log-level info
```

### Export specific RGs (recommended)
```bash
./exporter/ngs-template-exporter.sh   --subscription-id "00000000-0000-0000-0000-000000000000"   --rg rg-network-core-uks-01   --rg rg-network-core-uks-02   --outdir ./out   --log-level debug
```

### Disable VNet peerings emission
```bash
./exporter/ngs-template-exporter.sh --subscription-id <id> --no-vnet-peering
```

### Disable tags emission
```bash
./exporter/ngs-template-exporter.sh --subscription-id <id> --no-tags
```

### Include gateways/NAT & referenced IPs
```bash
./exporter/ngs-template-exporter.sh --subscription-id <id> --include natgw --include vnetgw
```

### Dump raw Azure payloads for inspection
```bash
./exporter/ngs-template-exporter.sh --subscription-id <id> --dump-raw
# files: vnets.<rg>.json, routeTables.<rg>.json, nsgs.<rg>.json, natGateways.<rg>.json, publicIPs.<rg>.json, publicIPPrefixes.<rg>.json, virtualNetworkGateways.<rg>.json
```

---

## Output
- `./out/resGrp-<RG>.network.json` — per‑RG network template (RG‑scoped)
- `./out/main.subscription.json` — subscription‑scope wrapper with nested deployments
- `./out/report.json` — summary (version, RGs included, raw edge list)

Deploy a dry‑run:
```bash
az deployment sub what-if   --name ngs-export-test   --location uksouth   --template-file ./out/main.subscription.json
```

---

## Parameters / Flags

| Flag | Type | Default | Description |
|---|---|---:|---|
| `--subscription-id` | string | (required) | Subscription to export. |
| `--rg` | string (repeatable) | *(all RGs)* | Restrict export to one or more RGs. |
| `--region-filter` | regex | `""` | Only include resources with matching `.location`. |
| `--include natgw` | switch | off | Emit NAT Gateways and their referenced PIPs/PIPPs, with correct `dependsOn` in the wrapper. |
| `--include vnetgw` | switch | off | Emit Virtual Network Gateways and their referenced PIPs, with correct `dependsOn` in the wrapper. |
| `--no-vnet-peering` | switch | on | Do not emit `virtualNetworkPeerings`. |
| `--outdir` | path | `./out` | Output directory. |
| `--log-level` | enum | `info` | `info` or `debug`. |
| `--debug` | switch | — | Alias for `--log-level debug`. |
| `--dump-raw` | switch | off | Save raw Azure CLI JSON payloads for each RG. |
| `--no-cross-rg-deps` | switch | off | Do **not** add inter‑RG `dependsOn` at subscription wrapper level (not recommended if you have peerings/gateways spanning RGs). |
| `--strict-safety` | switch | off | Fail export if unsafe empties/nulls detected in subnet props. |
| `--no-tags` | switch | off | Disable tag emission (tags are on by default). |

**Notes**
- Subnet tags are not supported by Azure (none emitted). Peerings also do not support tags.
- Wrapper nested deployments are **RG‑scoped** (no `location` on nested resource), complying with your v2.1.2 rule.

---

## Safety rules (critical)
- **Never emit** `[]` or `null` for properties that would **clear** current settings.
- Subnets: only emit
  - `serviceEndpoints` when **non‑empty** (service names only; locations/provisioning state omitted)
  - `delegations` when **non‑empty** (`name`, `properties.serviceName`)
  - `privateEndpointNetworkPolicies` / `privateLinkServiceNetworkPolicies` when **not null**
  - association IDs (`routeTable.id`, `networkSecurityGroup.id`, `natGateway.id`) only when present
- VNets/NSGs/RTs/Gateways/NAT GW/PIPs/PIPPs: preserve **tags** when present (unless `--no-tags`).

---

## Troubleshooting

### az CLI/jq version errors
- **Error:** `Your jq build does not support --argfile`  
  **Cause:** old jq. **Fix:** install jq ≥ 1.6.

- **Error:** `azure-cli <version> detected; require >= 2.40.0`  
  **Fix:** `az upgrade`

### jq syntax errors
- Ensure you’re running the included script for *this* version. We avoid jq “ternary” patterns; if you edited the script and see errors like *“unexpected '$'”*, restore from release.

### What‑If shows removals of tags
- Ensure you **did not** run with `--no-tags`.
- Verify `tags` appear in `resGrp-*.network.json` for the affected resource types.

### Wrapper dependency errors for peerings
- Make sure both sides of a peering are included in the export and that cross‑RG `dependsOn` is not disabled (`--no-cross-rg-deps`).

### Deny assignment failures
- Managed RGs (e.g., App Insights, AKS `MC_*`, etc.) often have **deny assignments**. Exclude them from export (`--rg` filter) or remove their nested deployments from the wrapper before deploying. Stack-level denies cannot override platform-managed denies.

---

## Known issues / behaviors
- Subnet `addressPrefixes` vs `addressPrefix`: exporter preserves whichever exists. If both exist in source, `addressPrefixes` takes precedence.
- Service Endpoint `locations` and `provisioningState` are intentionally **not** re-emitted.
- VNet peerings: we emit only supported properties and the remote VNet ID; read-only fields like `peeringSyncLevel` are suppressed.
- NAT GW & VNet GW: only PIP/PIPP references actually used by those resources are emitted.

---

## Example end‑to‑end (with peerings & tags)
```bash
./exporter/ngs-template-exporter.sh   --subscription-id "SUB_ID"   --rg rg-demo-core-uks-01   --rg rg-demo-core-uks-02   --include natgw --include vnetgw   --outdir ./out --log-level info

az deployment sub what-if   --name ngs-export-test   --location uksouth   --template-file ./out/main.subscription.json
```

---

## Compatibility
- Tested with **Stack Deployer (NGS v2 – Deployment Stack Wrapper) v2.1.2**
- Wrapper nests are `Microsoft.Resources/deployments` with `"resourceGroup": "<rg>"` and no `location`

---

## Logging & exit codes
- Logs to STDOUT/STDERR with UTC timestamps.
- Non‑zero exit on: missing deps, incompatible versions, Azure CLI failure (per command), or `--strict-safety` violations.

---

## Versioning
- Semantic style: **major.minor.build**, starting at **2.0.0**.  
- See **CHANGELOG.md** for details.
