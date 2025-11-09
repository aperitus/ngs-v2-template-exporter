#!/usr/bin/env bash
set -e
# Example: export two RGs
SUB="<SUB_ID>"
./exporter/ngs-template-exporter.sh   --subscription-id "$SUB"   --rg rg-demo-core-uks-01   --rg rg-demo-sec-uks-01   --outdir ./out   --normalize-address-prefix first   --log-level debug
