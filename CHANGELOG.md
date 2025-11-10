# Changelog

All notable changes to this tool are documented here. Dates in UTC.

All notable changes to this tool are documented here. Dates in UTC.
## 2025-11-10 – v2.0.14
- Fix: jq compile errors in v2.0.13
  - Corrected `choose_prefix_object` nested `if … end` chain.
  - Replaced edges regex `Microsoft\.Network` with `Microsoft[.]Network` in `capture()` to avoid invalid escapes.
- Keep: safe-emission behaviour from v2.0.13 (omit empties/nulls; prefer `addressPrefixes`).

## 2025-11-10 – v2.0.13
- Safe re-apply emission rules:
  - **Subnets:** only emit `serviceEndpoints` and `delegations` when non-empty; emit PE/PLS flags only when non-null; prefer `addressPrefixes` else `addressPrefix`.
  - **NSGs:** include ASG bindings and `description` when present; avoid empty arrays/nulls.
  - **Routes:** emit `nextHopIpAddress` only when set.
- Add: `--strict-safety` flag to **hard fail** CI on unsafe empties/nulls.

## 2025-11-09 – v2.0.12
- Fix: removed stray `- report.json` shell line causing non‑terminating error under `set -euo pipefail`.
- Add: explicit `exit 0` at end of script.
- Keep: all prior behaviour (delegations preserved, cycle‑safe deps, 4‑arg `resourceId`, `dep-<rg>` names).

## 2025-11-09 – v2.0.11
- Change: preserve **delegation names verbatim** as returned by Azure to avoid spurious what‑if rename.
- Keep: correct delegation object shape (`name` + `properties.serviceName`).

## 2025-11-09 – v2.0.10
- Fix: emit **delegations** in ARM‑compliant shape (strip read‑only fields; `properties.serviceName` only).

## 2025-11-09 – v2.0.9
- Fix: cross‑RG `dependsOn` now uses **4‑arg `resourceId(subscription().subscriptionId, rg, type, name)`**
  to correctly reference **RG‑scoped** nested deployments at the subscription scope.
- Add: `--no-cross-rg-deps` switch to strip inter‑RG dependencies from the wrapper.

## 2025-11-09 – v2.0.8
- Add: **cycle‑safe** inter‑RG dependency logic. If A↔B exists, keep only `(max(A,B) → min(A,B))`.
- Keep: prior fixes.

## 2025-11-09 – v2.0.7
- Add: **subnet delegations passthrough** (initial implementation).

## 2025-11-09 – v2.0.6
- Change: nested deployment names → `dep-<rg>` (avoid `rg-rg-*` confusion).
- Fix: safe quoting in `dependsOn` (`\u0027` single quotes) for embedded ARM expressions.

## 2025-11-09 – v2.0.5
- Fix: wrapper `dependsOn` quoting (inner **single quotes** instead of double) to satisfy ARM.

## 2025-11-09 – v2.0.1
- Initial v2 cut used during export trials: per‑RG templates + subscription wrapper, logging, prefix normalisation.
