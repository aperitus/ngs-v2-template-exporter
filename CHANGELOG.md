# Changelog

## [2.0.0] - 2025-11-09
### Added
- Initial release of **NGS v2 – Template Exporter**.
- Discovers VNets, Subnets, Route Tables (+ routes), NSGs (+ rules) across selected RGs or entire subscription.
- Emits per‑RG RG‑scoped ARM templates and a subscription‑scope wrapper.
- Fully‑qualified cross‑RG IDs for Subnet→UDR and Subnet→NSG.
- Logging (`--log-level`) and debug mode.
- `report.json` with normalization details.
