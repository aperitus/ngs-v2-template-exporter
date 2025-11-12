# NGS v2 – Template Exporter
**Version:** 2.0.26  
**Authored:** 2025-11-12T20:42:38Z
**Author:** Andrew Clarke

Export *safe-to-reapply* ARM JSON for Azure network guard rails (VNets, subnets, NSGs, route tables, NAT GW, VNet GW, public IPs/prefixes, VNet peerings) that can be deployed **as one subscription-scope template** by the **Stack Deployer (NGS v2 – Deployment Stack Wrapper) v2.1.2**.

---

## BLUF
- Produces one **subscription-scope wrapper** with **per‑RG nested deployments** (RG‑scoped; no `location` on nested resource).
- **Skips managed RGs by default** (those with `managedBy` or names ending `_managed`) to avoid deny assignment failures; override with `--include-managed`.
- **Never emits empty arrays or nulls** for properties that would **clear** settings.
- **Preserves tags** for supported resources (toggle with `--no-tags`).  
- Adds **inter‑RG `dependsOn`** (peerings, NAT/VNet GW PIPs) **only when remote is in the same subscription**.
- Compatible with **az CLI ≥ 2.40.0** and **jq ≥ 1.6** (must support `--argfile`).

---

## Version constraints (required)
- **azure-cli**: `>= 2.40.0` (validated up to 2.78.x)
- **jq**: `>= 1.6` and must support `--argfile`  
  The exporter preflights both and exits clearly if incompatible.

### Quick jq 1.6 on Ubuntu/WSL
```bash
sudo apt update && sudo apt install -y jq
jq --version  # expect jq-1.6
```
If needed, you can place the official jq-1.6 static binary into `~/.local/bin/jq` and ensure it is first in `PATH`.

---

## Installation
```bash
chmod +x exporter/ngs-template-exporter.sh
```

---

## Usage

### Export entire subscription
```bash
./exporter/ngs-template-exporter.sh --subscription-id "SUB_ID" --outdir ./out --log-level info
```

### Export specific RGs (recommended)
```bash
./exporter/ngs-template-exporter.sh --subscription-id "SUB_ID"   --rg rg-network-core-uks-01 --rg rg-network-core-uks-02   --include natgw --include vnetgw   --outdir ./out --log-level debug
```

### Disable VNet peerings emission
```bash
./exporter/ngs-template-exporter.sh --subscription-id SUB_ID --no-vnet-peering
```

### Disable tags emission
```bash
./exporter/ngs-template-exporter.sh --subscription-id SUB_ID --no-tags
```

### Include gateways/NAT & referenced IPs
```bash
./exporter/ngs-template-exporter.sh --subscription-id SUB_ID --include natgw --include vnetgw
```

### Dump raw Azure payloads for inspection
```bash
./exporter/ngs-template-exporter.sh --subscription-id SUB_ID --dump-raw
# files: vnets.<rg>.json, routeTables.<rg>.json, nsgs.<rg>.json, natGateways.<rg>.json, publicIPs.<rg>.json, publicIPPrefixes.<rg>.json, virtualNetworkGateways.<rg>.json
```

---

## Output
- `./out/resGrp-<RG>.network.json` — per‑RG network template (RG‑scoped)
- `./out/main.subscription.json` — subscription‑scope wrapper with nested deployments
- `./out/report.json` — summary (version, RGs included, raw edge list, skipped managed RGs)

Dry‑run:
```bash
az deployment sub what-if --name ngs-export-test --location uksouth --template-file ./out/main.subscription.json
```

---

## Parameters / Flags

| Flag | Type | Default | Description |
|---|---|---:|---|
| `--subscription-id` | string | (required) | Subscription to export. |
| `--rg` | string (repeatable) | *(all RGs)* | Restrict export to one or more RGs. |
| `--region-filter` | regex | `""` | Only include resources whose `.location` matches. |
| `--include natgw` | switch | off | Emit NAT Gateways + referenced PIPs/PIPPs, and wrapper deps. |
| `--include vnetgw` | switch | off | Emit Virtual Network Gateways + referenced PIPs, and wrapper deps. |
| `--no-vnet-peering` | switch | on | Do not emit `virtualNetworkPeerings`. |
| `--include-managed` | switch | off | Include RGs that are managed (`managedBy` or `_managed`). |
| `--no-cross-rg-deps` | switch | off | Do **not** add inter‑RG `dependsOn` in wrapper. |
| `--outdir` | path | `./out` | Output directory. |
| `--log-level` | enum | `info` | `info` or `debug`. |
| `--debug` | switch | — | Alias for `--log-level debug`. |
| `--dump-raw` | switch | off | Save raw Azure CLI JSON payloads per RG. |
| `--strict-safety` | switch | off | Fail export if unsafe empties/nulls detected in subnets. |
| `--no-tags` | switch | off | Disable tag emission (tags are on by default). |

**Notes**
- Subnet tags are not supported by Azure (none emitted). Peerings also do not support tags.
- Wrapper nests are **RG‑scoped** (no `location` on nested resource).

---

## Safety rules (critical)
- **Never emit** `[]` or `null` for properties that would **clear** live settings.
- Subnets: emit only when present/non-empty:
  - `serviceEndpoints` (service names only)
  - `delegations` (`name`, `properties.serviceName`)
  - `privateEndpointNetworkPolicies` / `privateLinkServiceNetworkPolicies` when not null
  - associations (`routeTable.id`, `networkSecurityGroup.id`, `natGateway.id`)
- VNets/NSGs/RTs/Gateways/NAT GW/PIPs/PIPPs: preserve **tags** (unless `--no-tags`).

---

## Troubleshooting

### Version preflight failures
- **Your jq build does not support `--argfile`** → install jq ≥ 1.6.
- **azure-cli too old** → `az upgrade`.

### Managed RG deny assignment
- Platform-managed RGs (App Insights, AKS `MC_*`, etc.) often have deny assignments. The exporter **skips them by default**. Use `--include-managed` only if you fully control deployment behavior and expect denies.

### Peerings and ordering
- Ensure both VNets are included in export for peerings. The wrapper only adds `dependsOn` edges when the remote VNet is in the **same subscription**. Cross-subscription relationships will deploy without artificial deps (to avoid invalid expressions).

### What‑If shows tag removals
- Confirm you did **not** run with `--no-tags`. Check `resGrp-*.network.json` has `tags` for those resources.

---

## Operators Cheat Sheet

### Fast path: export, review, dry-run
```bash
# export specific RGs with gateways/NAT and tags
./exporter/ngs-template-exporter.sh --subscription-id SUB_ID   --rg rg-demo-core-uks-01 --rg rg-demo-core-uks-02   --include natgw --include vnetgw --outdir ./out --log-level info

# review summary
cat ./out/report.json | jq

# what-if
az deployment sub what-if --name ngs-export-test --location uksouth --template-file ./out/main.subscription.json
```

### Partial rebuild after RG delete
- Re-export **both** RGs involved in any peerings.
- Apply wrapper; VNets/NSGs/RTs/NAT/VNG deploy first, then peerings.

### Skip problematic RGs
- By default, managed RGs are skipped. To explicitly exclude others, use multiple `--rg` flags selecting only what you want.

### Common error → action
| Error snippet | Action |
|---|---|
| `Your jq build does not support --argfile` | Install jq 1.6+ or replace with official 1.6 binary in `~/.local/bin`. |
| `Deny assignment check failed` | Likely a managed RG; exclude it (default) or remove that nested deployment. |
| `InvalidResourceReference` on VNet | Ensure local dependencies (NSG/RT/NAT) exist in same RG file; exporter emits deps automatically. |
| Peering shows `Disconnected` | Make sure both VNets exist; if stale remote peering remains, delete both peerings once and re-apply. |

---

## Compatibility
- Designed for **Stack Deployer (NGS v2 – Deployment Stack Wrapper) v2.1.2**.
- Wrapper uses nested `Microsoft.Resources/deployments` with `"resourceGroup": "<rg>"` and **no `location`** on the nested resource.

---

## License & Versioning
- Versioning: **major.minor.build**, starting at **2.0.0**.
- See **CHANGELOG.md** for full history.
