#!/usr/bin/env bash
set -euo pipefail

# NGS v2 – Template Exporter
# Dependencies: az, jq

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/log.sh"

VERSION="$(cat "$SCRIPT_DIR/version.txt" 2>/dev/null || echo "2.0.0")"

SUBSCRIPTION_ID=""
OUTDIR="./out"
RGS=()
REGION_FILTER=""
FORMAT="arm"
NORMALIZE_PREFIX="first"
INCLUDE_NATGW="false"
LOG_LEVEL="${LOG_LEVEL:-info}"

print_help() {
  cat <<EOF
Usage: $(basename "$0") --subscription-id <id> [options]

Options:
  --subscription-id <id>            Required
  --rg <name>                       Repeatable; if omitted, scans entire subscription
  --region-filter <regex>           Filter by Azure region name
  --include natgw                   Discover NAT Gateways (logged only for v2.0.0)
  --outdir <path>                   Output directory (default: ./out)
  --normalize-address-prefix first|fail  Default: first
  --format arm                      Only 'arm' supported
  --log-level info|debug            Default: info
  --debug                           Alias for --log-level debug
  -h, --help                        Show help
EOF
}

# Parse args
while [[ $# -gt 0 ]]; do
  case "$1" in
    --subscription-id) SUBSCRIPTION_ID="$2"; shift 2 ;;
    --rg) RGS+=("$2"); shift 2 ;;
    --outdir) OUTDIR="$2"; shift 2 ;;
    --region-filter) REGION_FILTER="$2"; shift 2 ;;
    --include) [[ "${2:-}" == "natgw" ]] && INCLUDE_NATGW="true"; shift 2 ;;
    --normalize-address-prefix) NORMALIZE_PREFIX="$2"; shift 2 ;;
    --format) FORMAT="$2"; shift 2 ;;
    --log-level) LOG_LEVEL="$2"; shift 2 ;;
    --debug) LOG_LEVEL="debug"; shift ;;
    -h|--help) print_help; exit 0 ;;
    *) log_err "Unknown arg: $1"; print_help; exit 1 ;;
  esac
done

if [[ -z "$SUBSCRIPTION_ID" ]]; then
  log_err "--subscription-id is required"
  exit 1
fi

if ! command -v az >/dev/null 2>&1; then
  log_err "Azure CLI (az) not found"
  exit 1
fi
if ! command -v jq >/dev/null 2>&1; then
  log_err "jq not found"
  exit 1
fi

mkdir -p "$OUTDIR"
REPORT="$OUTDIR/report.json"

log_info "NGS Template Exporter v$VERSION starting…"
log_info "Subscription: $SUBSCRIPTION_ID"
[[ ${#RGS[@]} -gt 0 ]] && log_info "RG filter: ${RGS[*]}" || log_info "RG filter: <none> (scan entire subscription)"
[[ -n "$REGION_FILTER" ]] && log_info "Region filter: $REGION_FILTER"
log_info "Normalize subnet addressPrefixes: $NORMALIZE_PREFIX"
[[ "$INCLUDE_NATGW" == "true" ]] && log_info "NATGW discovery: enabled (emit in future release)"
log_debug "Outdir: $OUTDIR"

# Set subscription for all az calls
az account set --subscription "$SUBSCRIPTION_ID"

# Gather RG list
if [[ ${#RGS[@]} -eq 0 ]]; then
  log_info "Discovering resource groups…"
  mapfile -t RGS < <(az group list --subscription "$SUBSCRIPTION_ID" --query "[].name" -o tsv | sort -u)
fi

# Accumulators
ALL_EDGES=()  # "consumerRG|producerRG|type|name"
RG_LIST=()

emit_rg_template() {
  local rg="$1"
  local outfile="$OUTDIR/rg-${rg}.network.json"

  log_info "RG [$rg]: discovering VNets"
  local vnets_json
  vnets_json="$(az network vnet list -g "$rg" -o json)"
  log_debug "RG [$rg]: VNets bytes $(echo -n "$vnets_json" | wc -c)"

  # Build base resources arrays
  local vnets resources routes nsgs

  # Route tables + routes in RG
  log_info "RG [$rg]: discovering Route Tables"
  local rts_json
  rts_json="$(az network route-table list -g "$rg" -o json)"
  log_debug "RG [$rg]: RouteTables bytes $(echo -n "$rts_json" | wc -c)"

  # NSGs
  log_info "RG [$rg]: discovering NSGs"
  local nsgs_json
  nsgs_json="$(az network nsg list -g "$rg" -o json)"
  log_debug "RG [$rg]: NSGs bytes $(echo -n "$nsgs_json" | wc -c)"

  # NATGW (placeholder)
  if [[ "$INCLUDE_NATGW" == "true" ]]; then
    az network nat gateway list -g "$rg" -o none || true
    log_info "RG [$rg]: NAT Gateways discovered (logging only in v2.0.0)"
  fi

  # Build resources via jq
  local template
  template="$(jq -n \
    --arg subId "$SUBSCRIPTION_ID" \
    --arg rg "$rg" \
    --arg normalize "$NORMALIZE_PREFIX" \
    --arg regionFilter "$REGION_FILTER" \
    --argjson vnets "$vnets_json" \
    --argjson rts "$rts_json" \
    --argjson nsgs "$nsgs_json" \
    '
    def loc_ok:
      if $regionFilter == "" then true
      else (.location // "" | test($regionFilter))
      end;

    def fqid($rg; $type; $name):
      {
        "id": ("[resourceId(subscription().subscriptionId,\($rg),\"" + $type + "\",\($name) + ")]")
      };

    def rt_resources:
      [ ($rts[] | select(loc_ok)) as $rt |
        {
          "type": "Microsoft.Network/routeTables",
          "apiVersion": "2023-11-01",
          "name": $rt.name,
          "location": $rt.location,
          "properties": {
            "routes":
              [ ($rt.routes // [])[]
                | {
                    "name": .name,
                    "properties": {
                      "addressPrefix": .addressPrefix,
                      "nextHopType": .nextHopType,
                      "nextHopIpAddress": .nextHopIpAddress
                    }
                  }
              ]
          }
        }
      ];

    def nsg_resources:
      [ ($nsgs[] | select(loc_ok)) as $n |
        {
          "type": "Microsoft.Network/networkSecurityGroups",
          "apiVersion": "2023-11-01",
          "name": $n.name,
          "location": $n.location,
          "properties": {
            "securityRules":
              [ ($n.securityRules // [])[]
                | {
                    "name": .name,
                    "properties": {
                      "priority": .priority,
                      "direction": .direction,
                      "access": .access,
                      "protocol": .protocol,
                      "sourcePortRange": .sourcePortRange,
                      "destinationPortRange": .destinationPortRange,
                      "sourcePortRanges": .sourcePortRanges,
                      "destinationPortRanges": .destinationPortRanges,
                      "sourceAddressPrefix": .sourceAddressPrefix,
                      "destinationAddressPrefix": .destinationAddressPrefix,
                      "sourceAddressPrefixes": .sourceAddressPrefixes,
                      "destinationAddressPrefixes": .destinationAddressPrefixes
                    }
                  }
              ]
          }
        }
      ];

    def vnet_resources:
      [ ($vnets[] | select(loc_ok)) as $v |
        {
          "type": "Microsoft.Network/virtualNetworks",
          "apiVersion": "2023-11-01",
          "name": $v.name,
          "location": $v.location,
          "properties": {
            "addressSpace": $v.properties.addressSpace,
            "subnets":
              [ ($v.subnets // [])[] as $s |
                (
                  if ($s.properties.addressPrefix == null)
                  then
                    if ($s.properties.addressPrefixes // [] | length) == 0 then
                      error("subnet has no addressPrefix(es): \($s.name) in VNet \($v.name)")
                    else
                      if $normalize == "first"
                      then .
                      else error("multiple addressPrefixes found; use --normalize-address-prefix first")
                      end
                    end
                  else .
                  end
                )
                | {
                    "name": $s.name,
                    "properties": (
                      {
                        "addressPrefix":
                          ( if $s.properties.addressPrefix != null
                            then $s.properties.addressPrefix
                            else ($s.properties.addressPrefixes[0])
                            end ),
                        "privateEndpointNetworkPolicies": $s.properties.privateEndpointNetworkPolicies,
                        "privateLinkServiceNetworkPolicies": $s.properties.privateLinkServiceNetworkPolicies,
                        "serviceEndpoints": $s.properties.serviceEndpoints
                      }
                      + ( if ($s.properties.routeTable.id // "") != "" then
                            { "routeTable":
                                { "id":
                                  ("[resourceId(subscription().subscriptionId,\""
                                   + ($s.properties.routeTable.id | split(\"/\")[4]) + "\",\"Microsoft.Network/routeTables\",\""
                                   + ($s.properties.routeTable.id | split(\"/\")[-1]) + "\")]")
                                }
                              }
                          else {} end )
                      + ( if ($s.properties.networkSecurityGroup.id // "") != "" then
                            { "networkSecurityGroup":
                                { "id":
                                  ("[resourceId(subscription().subscriptionId,\""
                                   + ($s.properties.networkSecurityGroup.id | split(\"/\")[4]) + "\",\"Microsoft.Network/networkSecurityGroups\",\""
                                   + ($s.properties.networkSecurityGroup.id | split(\"/\")[-1]) + "\")]")
                                }
                              }
                          else {} end )
                    )
                  }
              ]
          },
          "dependsOn":
            (
              # subnets may reference RT/NSG in this or other RGs; add local depends for same-RG producers
              [ ($v.subnets // [])[] as $s |
                  ([$s.properties.routeTable.id, $s.properties.networkSecurityGroup.id] | map(select(. != null))[]) as $ref
                | if ($ref | split(\"/\")[4]) == $rg then
                    ( if ($ref | split(\"/\")[7]) == "routeTables"
                      then "[resourceId(\"Microsoft.Network/routeTables\", \($ref | split(\"/\")[-1]))]"
                      else "[resourceId(\"Microsoft.Network/networkSecurityGroups\", \($ref | split(\"/\")[-1]))]"
                      end )
                  else empty end
              ]
            )
        }
      ];

    {
      "$schema": "https://schema.management.azure.com/schemas/2019-04-01/deploymentTemplate.json#",
      "contentVersion": "1.0.0.0",
      "resources": (rt_resources + nsg_resources + vnet_resources)
    }')"

  echo "$template" | jq '.' > "$outfile"
  log_info "RG [$rg]: wrote $(basename "$outfile")"

  # Collect cross-RG edges for dependsOn in subscription wrapper
  local edges
  edges="$(echo "$template" | jq -r --arg rg "$rg" '
    [ .resources[]
      | select(.type=="Microsoft.Network/virtualNetworks")
      | (.properties.subnets // [] )[]
      | [ .properties.routeTable.id?, .properties.networkSecurityGroup.id? ] | map(select(. != null))[]
      | select(startswith("[resourceId("))
      | capture("\\[resourceId\\(subscription\\(\\)\\.subscriptionId,\\\"(?<prodRG>[^\\\"]+)\\\",\\\"(?<rtype>[^\\\"]+)\\\",\\\"(?<rname>[^\\\"]+)\\\"\\)\\]")
      | "\\($rg)|\\(.prodRG)|\\(.rtype)|\\(.rname)"
    ] | .[]
  ')"
  if [[ -n "$edges" ]]; then
    while IFS= read -r line; do
      ALL_EDGES+=("$line")
    done <<< "$edges"
  fi
}

# Emit per-RG templates
for rg in "${RGS[@]}"; do
  RG_LIST+=("$rg")
  emit_rg_template "$rg"
done

# Build subscription wrapper
SW="$OUTDIR/main.subscription.json"
log_info "Building subscription-scope wrapper…"

# Build dependsOn map from edges
# Format: consumerRG|producerRG|type|name
# We only need RG-level ordering; compute consumers -> producers list
depends_map = {}
dep_pairs = []

# Prepare resources array for wrapper
# Each RG becomes a nested deployment with inline template read from file
resources_json="[]"
for rg in "${RGS[@]}"; do
  tmpl_path="$OUTDIR/rg-${rg}.network.json"
  # Inline the template
  rg_template="$(cat "$tmpl_path")"
  dep_list="[]"
  # RG-level dependsOn derived from edges where consumerRG==rg
  if [[ ${#ALL_EDGES[@]} -gt 0 ]]; then
    dep_list="$(printf "%s\n" "${ALL_EDGES[@]}" | awk -F'|' -v rg="$rg" '$1==rg && $1!=$2 {print $2}' | sort -u | jq -R -s 'split("\n")|map(select(length>0))')"
  fi

  resources_json="$(jq -n \
    --arg rg "$rg" \
    --argjson tmpl "$rg_template" \
    --argjson deps "$dep_list" \
    --arg location "uksouth" \
    --arg name "rg-\($rg)" \
    --arg deploymentName "rg-\($rg)" \
    --argjson current "$resources_json" \
    '
    def dep_res($depRg):
      { "type":"Microsoft.Resources/deployments",
        "apiVersion":"2021-04-01",
        "name": ("rg-" + $depRg),
        "resourceGroup": $depRg,
        "location": null };

    $current + [{
      "type": "Microsoft.Resources/deployments",
      "apiVersion": "2021-04-01",
      "name": ("rg-" + $rg),
      "resourceGroup": $rg,
      "properties": {
        "mode": "Incremental",
        "expressionEvaluationOptions": {"scope":"inner"},
        "template": $tmpl
      },
      "dependsOn":
        ( ($deps | map("[subscription().subscriptionId, \"" + . + "\"]")) as $junk  # placeholder
          | ( $deps | map( "[resourceId(\'Microsoft.Resources/deployments\', \'rg-" + . + "\')]" ) )
        )
    }]
    ' )"
done

# Assemble wrapper
jq -n \
  --arg version "$VERSION" \
  --arg subId "$SUBSCRIPTION_ID" \
  --argjson resources "$resources_json" \
'{
  "$schema":"https://schema.management.azure.com/schemas/2019-04-01/deploymentTemplate.json#",
  "contentVersion":"1.0.0.0",
  "metadata":{
    "x-ngs-version":$version,
    "x-generated-utc": (now|todate)
  },
  "resources": $resources
}' > "$SW"

log_info "Wrote $(basename "$SW")"

# Emit report
jq -n \
  --arg version "$VERSION" \
  --arg subId "$SUBSCRIPTION_ID" \
  --argjson edges "$(printf "%s\n" "${ALL_EDGES[@]}" | jq -R -s 'split("\n")|map(select(length>0))')" \
  --argjson rgs "$(printf "%s\n" "${RGS[@]}" | jq -R -s 'split("\n")|map(select(length>0))')" \
  '{
    "version": $version,
    "subscriptionId": $subId,
    "resourceGroups": $rgs,
    "crossRgEdges": $edges
  }' > "$REPORT"

log_info "Done. Outputs in: $OUTDIR"
