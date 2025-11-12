# NGS v2 – Operator Cheat Sheet (v2.0.26)

## 0) Quick preflight
```bash
az --version | head -n1           # azure-cli >= 2.40.0
jq --version                      # jq-1.6 (or newer) and supports --argfile
```

## 1) Export the target
```bash
./exporter/ngs-template-exporter.sh --subscription-id SUB_ID   --rg rg-demo-core-uks-01 --rg rg-demo-core-uks-02   --include natgw --include vnetgw   --outdir ./out --log-level info
```

## 2) Review
```bash
cat ./out/report.json | jq
ls -1 ./out/resGrp-*.network.json
```

## 3) Dry-run
```bash
az deployment sub what-if --name ngs-export-test --location uksouth   --template-file ./out/main.subscription.json
```

## 4) Apply (via Stack Deployer module) — typical
- Use the Terraform wrapper module (v2.1.2). Point it at `./out/main.subscription.json`.
- Keep mode **Incremental**.

## 5) Partial rebuild (after RG deletion)
- Re-export the affected RG(s) **plus any peering partners**.
- Apply wrapper; peerings deploy after VNets.

## 6) Managed RGs / Deny Assignments
- Skipped by default. Use `--include-managed` only if you intend to handle denies yourself.

## 7) Tags
- Emitted by default. Use `--no-tags` to suppress.

## 8) Common issues
| Symptom | Fix |
|---|---|
| jq argfile error | Install jq 1.6+ or place static 1.6 in `~/.local/bin`. |
| Deny assignment failure | Exclude that RG (managed) or remove its nested deployment. |
| Peering fails | Ensure both VNets exist; re-export both RGs. |
| Unexpected tag removals | Ensure you didn’t use `--no-tags`. |

## 9) Useful variants
```bash
# export entire sub (skips managed RGs)
./exporter/ngs-template-exporter.sh --subscription-id SUB_ID --outdir ./out

# disable peerings (if you manage them separately)
./exporter/ngs-template-exporter.sh --subscription-id SUB_ID --no-vnet-peering

# emit without tags
./exporter/ngs-template-exporter.sh --subscription-id SUB_ID --no-tags
```
