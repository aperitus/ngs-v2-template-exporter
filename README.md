# NGS v2 – Template Exporter

**BLUF:** Exports Azure Virtual Network topology (VNets, subnets, UDRs, NSGs) into
**per-RG ARM templates** and a **subscription-scope wrapper** that can be
`what-if`/deployed idempotently. Designed to feed the Net Guard Deployment Stack.

---

## Features
- **Per-RG templates**: `resGrp-<rg>.network.json` for VNets, route tables, and NSGs.
- **Subscription wrapper**: `main.subscription.json` stitches RG templates together.
- **Cross-RG safe**: builds `dependsOn` between RG deployments using **4-arg `resourceId`**
  to target the **RG-scoped** nested deployments at **subscription scope**.
- **Cycle breaking**: if A↔B dependencies exist, only **max(A,B) → min(A,B)** is kept.
- **Safe re-apply (v2.0.13+)**: exporter **omits** empty arrays/`null` for mutable props to avoid clobbering.
- **Subnet fidelity**: preserves prefixes, service endpoints (only when present), delegations (correct shape),
  and day‑2 flags when set.
- **NSG fidelity**: includes ASG bindings and `description` **when present**.
- **Deterministic output**: stable ordering for clean diffs.
- **Logging & debugging**: `--log-level`, raw dumps (`--dump-raw`), and **`--strict-safety`** for CI hard‑fail.

## Requirements
- Bash (Linux/macOS/WSL)
- Azure CLI ≥ 2.40 (tested with 2.78.0)
- jq 1.6+

## Install
Copy the `exporter/` folder into your repo (do **not** version the filename).
You’ll have:
```
exporter/
  ngs-template-exporter.sh
  lib/log.sh
  version.txt
```

## Usage
Basic (single RG):
```bash
./exporter/ngs-template-exporter.sh \
  --subscription-id "<subId>" \
  --rg rg-demo-core-uks-01 \
  --outdir ./out \
  --log-level info
```

Multiple RGs:
```bash
./exporter/ngs-template-exporter.sh \
  --subscription-id "<subId>" \
  --rg rg-demo-core-uks-01 \
  --rg rg-demo-core-uks-02 \
  --outdir ./out
```

Whole subscription:
```bash
./exporter/ngs-template-exporter.sh \
  --subscription-id "<subId>" \
  --outdir ./out
```

Skip cross-RG dependencies (handy when exporting just one RG):
```bash
./exporter/ngs-template-exporter.sh ... --no-cross-rg-deps
```

Dump raw Azure payloads for inspection:
```bash
./exporter/ngs-template-exporter.sh ... --dump-raw --log-level debug
```

## CLI Options

| Option | Description | Why/When to use it |
|---|---|---|
| `--subscription-id <id>` | **Required.** Azure subscription GUID to target. | Ensures discovery and wrapper deployments are scoped to the correct subscription; always include this. |
| `--rg <name>` | Resource group filter (repeatable). If omitted, scans the entire subscription. | Use multiple `--rg` flags to export only the RGs you plan to what-if/apply now, speeding up runs and reducing noise. |
| `--region-filter <regex>` | Filter discovered resources by Azure region name (regex). | Helpful in large estates to limit output to regions like `^uk(south\|west)$`. |
| `--include natgw` | Also discover NAT Gateways (logged only for now). | Enables forward-compat logging so you can see NATGW inventory before emit support. |
| `--outdir <path>` | Output directory (default: `./out`). | Keep exports separate per run or repo; useful for CI artifacts. |
| `--log-level info\|debug` | Controls verbosity (default: `info`). | Flip to `debug` when validating edge cases or investigating missing resources. |
| `--debug` | Shortcut for `--log-level debug`. | Faster than typing the full flag; recommended during initial setup. |
| `--dump-raw` | Save raw Azure payloads for each RG. | Creates `vnets.<rg>.json`, `routeTables.<rg>.json`, `nsgs.<rg>.json` for offline inspection and diffing. |
| `--no-cross-rg-deps` | Do **not** add inter-RG `dependsOn` in the wrapper. | Use when exporting/applying a single RG in isolation, or when you want to hand-stage dependency order across RGs. |
| `--strict-safety` | Fail the run if unsafe empties/nulls are detected post-emit. | Turn this on in CI to **hard fail** any template that might clobber live settings. |
| `-h` / `--help` | Show usage help and exit. | Quick reference for flags and defaults without opening the README. |

## Safe Emission Rules (v2.0.13+)
**Goal:** *Include when non-empty; omit when empty; never null.* This prevents Azure RPs from interpreting empties as “clear configuration.”

- **Subnets**
  - `serviceEndpoints`: emitted **only when non-empty**.
  - `privateEndpointNetworkPolicies` / `privateLinkServiceNetworkPolicies`: emitted **only when not null**.
  - `delegations`: emitted **only when non-empty** (names preserved; correct `properties.serviceName`).
  - **Prefixes:** if `addressPrefixes[]` exists, we emit **`addressPrefixes`**; else we emit **`addressPrefix`**.
- **NSGs**
  - Rules include **ASG bindings** (`source/destinationApplicationSecurityGroups`) and **`description`** when present.
  - No empty arrays/`null` fields emitted.
- **Route Tables**
  - Each route includes `name`, `addressPrefix`, `nextHopType` and `nextHopIpAddress` **only if set**.

## Outputs
- `./out/main.subscription.json` — subscription-scope wrapper:
  - Nested deployments named `dep-<rg>`
  - Cross-RG `dependsOn` using:
    ```
    [resourceId(subscription().subscriptionId, '<rg>', 'Microsoft.Resources/deployments', 'dep-<rg>')]
    ```
  - Cycle-safe ordering.
- `./out/resGrp-<rg>.network.json` — RG-scoped ARM with:
  - `Microsoft.Network/virtualNetworks` (subnets inline; safe emission)
  - `Microsoft.Network/routeTables`
  - `Microsoft.Network/networkSecurityGroups`
- `./out/report.json` — run metadata and the raw cross-RG edge list.

## What-If / Deploy
```bash
az deployment sub what-if   --name ngs-export-test   --location uksouth   --template-file ./out/main.subscription.json

az deployment sub create   --name ngs-export-apply   --location uksouth   --template-file ./out/main.subscription.json
```

## Troubleshooting
- **“Resource ... is not defined in the template”**  
  Export all RGs referenced by cross-RG associations **or** use `--no-cross-rg-deps`.
- **“InvalidTemplate ... ResourceId string character ... not expected”**  
  Wrapper uses correct single-quote escaping inside ARM functions.
- **Delegation validation errors**  
  Exporter outputs correct shape; verify delegation **name** matches Azure exactly.
- **Cycles** (A depends on B and B depends on A)  
  The exporter keeps only `max(A,B) → min(A,B)` to remove the cycle.
- **jq errors (v2.0.13)**  
  If you saw regex/if-chain jq errors, upgrade to **v2.0.14** (fixed).

## Versioning
Semantic: **major.minor.build** (starting at `2.0.0`).  
This repo currently tracks builds `2.0.1` .. `2.0.14`.

## Author
Andrew Clarke

## License
MIT
