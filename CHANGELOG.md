# CHANGELOG

## v2.0.26
- **Default safety:** Skip **managed** resource groups (those with `managedBy` or names ending with `_managed`) to avoid deny-assignments and platform-owned artifacts breaking deployments.
- **Flag:** `--include-managed` to override the skip and include managed RGs.
- **Cross-subscription hardening:** Inter‑RG `dependsOn` derived from VNet peerings are added **only when the remote VNet is in the same subscription**. Prevents invalid cross‑subscription dependencies in the wrapper.
- **Compatibility:** Verified jq **1.6** syntax and kept behavior compatible with jq **1.7** (no reliance on new-only features).
- **Docs:** README expanded (operators cheat sheet, managed RG behavior, cross‑sub guidance).

## v2.0.25
- **Fix:** jq syntax errors from prior “ternary-like” patterns removed; replaced with valid `if/then/else` and additive objects.
- **Feature:** Tag preservation **on by default** across VNets, NSGs, RTs, NAT GW, VNet GW, PIPs, PIPPs.
- **Option:** `--no-tags` to disable tag emission.
- **Reliability:** Stronger peering/PIP dependency graphing and null-remote peering guard.
- **Docs:** Expanded README (BLUF, parameters, troubleshooting, known issues, version constraints).

## v2.0.24
- **Feature:** Initial tag preservation logic (now superseded), surfaced `Emit tags: ON` in logs.
- **Fix:** Inter-RG `dependsOn` string rendering corrected to ARM expression format.

## v2.0.23
- **Feature:** NAT Gateway + referenced Public IP/Prefix discovery & emission; dependency edges added to wrapper.
- **Feature:** VNet Gateway + referenced PIP discovery & emission; dependency edges added to wrapper.

## v2.0.22
- **Fix:** Cross-RG peering `dependsOn` generation corrected; ensures remote RG deployment runs before peering resources.
- **Change:** Wrapper uses per-RG nested deployments with **no `location`** on nested resource (RG-scoped rule).

## v2.0.21
- **Safety:** Subnet emission hardened — omit empty arrays/nulls for `serviceEndpoints`, `delegations`, `*NetworkPolicies`.
- **Docs:** Safety section added; guidance on what-if checks and empties detection.

## v2.0.20
- **Feature:** VNet peering emission enabled by default; exporter enumerates peerings via `az network vnet peering list` per VNet.
- **Fix:** Skip peerings with `remoteVirtualNetwork.id == null`.

## v2.0.19
- **Feature:** Inter‑RG dependency edges extracted from peerings; wrapper auto-adds `dependsOn` for producer→consumer RGs.
- **Fix:** Wrapper names standardized: `dep-<rg>`. Per‑RG files renamed `resGrp-<rg>.network.json`.

## v2.0.18
- **Fix:** Escaping/quoting issues in `dependsOn` ARM expressions resolved (no backslash artifacts).
- **Diagnostics:** Added `report.json` with edges list and RG inventory.

## v2.0.17
- **Fix:** Syntax error near unexpected token from Bash arithmetic/arrays corrected.
- **Feature:** `--dump-raw` to emit raw Azure payloads for inspection.

## v2.0.16
- **Safety:** Single-template strategy validated — exporter omits destructive empties/nulls to avoid clobbering live config.
- **Docs:** Added guidance for single-template re-apply with Stack Deployer v2.1.2.

## v2.0.15
- **Fix:** Resource file naming normalized (`resGrp-<rg>.network.json`); avoided `rg-rg-` confusion.
- **Docs:** Example commands updated.

## v2.0.14
- **Fix:** JQ quoting/escaping repaired for Windows/WSL shells.
- **Feature:** `--no-cross-rg-deps` to disable wrapper `dependsOn` generation (advanced).

## v2.0.13
- **Fix:** JQ filter compile errors (unterminated if/capture escapes) resolved.
- **Feature:** Early error messages now include the failing JQ line context.

## v2.0.12
- **Feature:** Baseline that fully round-trips VNets, subnets, NSGs, route tables with safe rules; minimal peerings.
- **Docs:** Initial README and examples.

## v2.0.11 and earlier
- Early iterations, internal builds aligning with Net Guard Deployment Stack **v0.27** rules and exporter hardening.
