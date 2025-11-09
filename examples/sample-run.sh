#!/usr/bin/env bash
set -e
SUB="<SUB_ID>"
./exporter/ngs-template-exporter.sh   --subscription-id "$SUB"   --rg rg-demo-core-uks-01   --outdir ./out   --normalize-address-prefix first   --log-level debug   --dump-raw
