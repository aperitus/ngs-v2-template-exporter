#!/usr/bin/env bash
# NGS v2 – Template Exporter (v2.0.12)
set -euo pipefail
set -o errtrace
trap 'echo "$(date -u +%FT%TZ) ERROR  Failed at ${BASH_SOURCE[0]}:${LINENO}: ${BASH_COMMAND}" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "$SCRIPT_DIR/lib/log.sh" ]]; then source "$SCRIPT_DIR/lib/log.sh"; else
  LOG_LEVEL="${LOG_LEVEL:-info}"; ts() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }
  _lvl() { case "${LOG_LEVEL}" in debug) echo 10;; info) echo 20;; *) echo 20;; esac; }
  _ok()  { local need=20; [[ "${1}" == "DEBUG" ]] && need=10; [[ $(_lvl) -le $need ]]; }
  log_info()  { _ok INFO  && echo "$(ts) INFO  $*"; }
  log_debug() { _ok DEBUG && echo "$(ts) DEBUG $*"; }
  log_err()   { echo "$(ts) ERROR $*" >&2; }
fi

VERSION="$(cat "$SCRIPT_DIR/version.txt" 2>/dev/null || echo "2.0.12")"

SUBSCRIPTION_ID=""
OUTDIR="./out"
RGS=()
REGION_FILTER=""
NORMALIZE_PREFIX="first"
INCLUDE_NATGW="false"
DUMP_RAW="false"
NO_CROSS_RG_DEPS="false"

print_help() {
  cat <<EOF
Usage: $(basename "$0") --subscription-id <id> [options]

Options:
  --subscription-id <id>            Required
  --rg <name>                       Repeatable; if omitted, scans entire subscription
  --region-filter <regex>           Filter by Azure region name
  --include natgw                   Discover NAT Gateways (logged only)
  --outdir <path>                   Output directory (default: ./out)
  --normalize-address-prefix first|fail  Default: first
  --log-level info|debug            Default: info
  --debug                           Alias for --log-level debug
  --dump-raw                        Save raw Azure payloads per RG
  --no-cross-rg-deps                Do NOT add inter-RG dependsOn in wrapper
  -h|--help                         Show help
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --subscription-id) SUBSCRIPTION_ID="$2"; shift 2 ;;
    --rg) RGS+=("$2"); shift 2 ;;
    --outdir) OUTDIR="$2"; shift 2 ;;
    --region-filter) REGION_FILTER="$2"; shift 2 ;;
    --include) [[ "${2:-}" == "natgw" ]] && INCLUDE_NATGW="true"; shift 2 ;;
    --normalize-address-prefix) NORMALIZE_PREFIX="$2"; shift 2 ;;
    --log-level) LOG_LEVEL="$2"; shift 2 ;;
    --debug) LOG_LEVEL="debug"; shift ;;
    --dump-raw) DUMP_RAW="true"; shift ;;
    --no-cross-rg-deps) NO_CROSS_RG_DEPS="true"; shift ;;
    -h|--help) print_help; exit 0 ;;
    *) log_err "Unknown arg: $1"; print_help; exit 1 ;;
  esac
done

[[ -z "$SUBSCRIPTION_ID" ]] && { log_err "--subscription-id is required"; exit 1; }
command -v az >/dev/null 2>&1 || { log_err "Azure CLI (az) not found"; exit 2; }
command -v jq >/dev/null 2>&1 || { log_err "jq not found"; exit 2; }

mkdir -p "$OUTDIR"
REPORT="$OUTDIR/report.json"
SW="$OUTDIR/main.subscription.json"
TMP_RES="$OUTDIR/.resources.json"

log_info "NGS Template Exporter v$VERSION starting…"
log_info "Subscription: $SUBSCRIPTION_ID"
[[ ${#RGS[@]} -gt 0 ]] && log_info "RG filter: ${RGS[*]}" || log_info "RG filter: <none>"
[[ -n "$REGION_FILTER" ]] && log_info "Region filter: $REGION_FILTER"
[[ "$DUMP_RAW" == "true" ]] && log_info "Raw dumps: enabled"

az account set --subscription "$SUBSCRIPTION_ID"

az_json() {
  if out="$(az "$@" -o json 2> >(tee /tmp/ngs-az.err >&2))"; then printf '%s' "$out"; else
    log_err "Azure CLI failed: az $* (stderr: /tmp/ngs-az.err)"; printf '[]'; fi
}

if [[ ${#RGS[@]} -eq 0 ]]; then
  mapfile -t RGS < <(az_json group list --subscription "$SUBSCRIPTION_ID" | jq -r '.[].name' | sort -u)
fi

ALL_EDGES=() # "consumerRG|producerRG|rtype|name"

emit_rg_template() {
  local rg="$1"
  local outfile="$OUTDIR/resGrp-${rg}.network.json"

  local vnets_json rts_json nsgs_json
  vnets_json="$(az_json network vnet list -g "$rg")"
  rts_json="$(az_json network route-table list -g "$rg")"
  nsgs_json="$(az_json network nsg list -g "$rg")"
  if [[ "$DUMP_RAW" == "true" ]]; then
    echo "$vnets_json" > "$OUTDIR/vnets.${rg}.json"
    echo "$rts_json"   > "$OUTDIR/routeTables.${rg}.json"
    echo "$nsgs_json"  > "$OUTDIR/nsgs.${rg}.json"
  fi

  JQ_PROG="$(mktemp)"
  cat > "$JQ_PROG" <<'JQ'
    def loc_ok($filter):
      if ($filter == "") then true else (.location // "" | test($filter)) end;

    def has_prefix:
      (.addressPrefix != null) or ((.addressPrefixes // []) | length > 0);

    def choose_prefix($normalize):
      if .addressPrefix != null then .addressPrefix
      else (.addressPrefixes[0])
      end;

    def rt_resources($rts; $filter):
      [ ($rts[]? | select(loc_ok($filter))) as $rt |
        {
          "type":"Microsoft.Network/routeTables",
          "apiVersion":"2023-11-01",
          "name":$rt.name,
          "location":$rt.location,
          "properties":{ "routes":
            [ ($rt.routes // [])[]?
              | { "name": .name, "properties": {
                    "addressPrefix": .addressPrefix,
                    "nextHopType": .nextHopType,
                    "nextHopIpAddress": .nextHopIpAddress } } ] }
        } ];

    def nsg_resources($nsgs; $filter):
      [ ($nsgs[]? | select(loc_ok($filter))) as $n |
        {
          "type":"Microsoft.Network/networkSecurityGroups",
          "apiVersion":"2023-11-01",
          "name":$n.name,
          "location":$n.location,
          "properties":{ "securityRules":
            [ ($n.securityRules // [])[]?
              | { "name": .name, "properties": {
                    "priority": .priority, "direction": .direction, "access": .access, "protocol": .protocol,
                    "sourcePortRange": .sourcePortRange, "destinationPortRange": .destinationPortRange,
                    "sourcePortRanges": .sourcePortRanges, "destinationPortRanges": .destinationPortRanges,
                    "sourceAddressPrefix": .sourceAddressPrefix, "destinationAddressPrefix": .destinationAddressPrefix,
                    "sourceAddressPrefixes": .sourceAddressPrefixes, "destinationAddressPrefixes": .destinationAddressPrefixes } } ] }
        } ];

    def map_delegations:
      [ (.delegations // [])[]?
        | { "name": (.name // "delegation"),
            "properties": { "serviceName": ( .properties.serviceName // .serviceName ) } } ];

    def vnet_resources($vnets; $filter; $normalize):
      [ ($vnets[]? | select(loc_ok($filter))) as $v |
        {
          "type":"Microsoft.Network/virtualNetworks",
          "apiVersion":"2023-11-01",
          "name":$v.name,
          "location":$v.location,
          "properties":{
            "addressSpace": $v.addressSpace,
            "subnets":
              [ ($v.subnets // [])[]?
                | select(has_prefix)
                | . as $s
                | { "name": $s.name,
                    "properties": (
                      { "addressPrefix": ( $s | choose_prefix($normalize) ),
                        "delegations": ( $s | map_delegations ),
                        "privateEndpointNetworkPolicies": $s.privateEndpointNetworkPolicies,
                        "privateLinkServiceNetworkPolicies": $s.privateLinkServiceNetworkPolicies,
                        "serviceEndpoints": $s.serviceEndpoints }
                      + ( if ($s.routeTable.id // "") != "" then { "routeTable": { "id": $s.routeTable.id } } else {} end )
                      + ( if ($s.networkSecurityGroup.id // "") != "" then { "networkSecurityGroup": { "id": $s.networkSecurityGroup.id } } else {} end )
                    ) }
              ]
          },
          "dependsOn":[]
        } ];

    {
      "$schema":"https://schema.management.azure.com/schemas/2019-04-01/deploymentTemplate.json#",
      "contentVersion":"1.0.0.0",
      "resources":
        ( rt_resources($rts; $regionFilter)
        + nsg_resources($nsgs; $regionFilter)
        + vnet_resources($vnets; $regionFilter; $normalize) )
    }
JQ

  local template
  if ! template="$(jq -n -f "$JQ_PROG" \
        --arg regionFilter "$REGION_FILTER" \
        --arg normalize "$NORMALIZE_PREFIX" \
        --argjson vnets "$vnets_json" \
        --argjson rts "$rts_json" \
        --argjson nsgs "$nsgs_json")"; then
    log_err "Template build failed for RG [$rg] — writing skeleton."
    template='{ "$schema":"https://schema.management.azure.com/schemas/2019-04-01/deploymentTemplate.json#", "contentVersion":"1.0.0.0", "resources":[] }'
  fi
  rm -f "$JQ_PROG"

  echo "$template" | jq '.' > "$outfile"
  log_info "RG [$rg]: wrote $(basename "$outfile")"

  # edges
  local edges
  edges="$(echo "$template" | jq -r --arg rg "$rg" '
    [ .resources[]? | select(.type=="Microsoft.Network/virtualNetworks")
      | (.properties.subnets // [])[]?
      | [ .properties.routeTable.id?, .properties.networkSecurityGroup.id? ] | map(select(. != null))[]
      | capture("/resourceGroups/(?<prodRG>[^/]+)/providers/(?<rtype>Microsoft\\.Network/[^/]+)/(?<rname>[^/]+)$")
      | "\($rg)|\(.prodRG)|\(.rtype)|\(.rname)"
    ] | .[]?')"
  if [[ -n "${edges:-}" ]]; then
    while IFS= read -r line; do [[ -n "$line" ]] && ALL_EDGES+=("$line"); done <<< "$edges"
  fi
}

for rg in "${RGS[@]}"; do
  emit_rg_template "$rg"
done

# Serialize edges for jq logic
EDGES_JSON="$(printf "%s\n" "${ALL_EDGES[@]:-}" | jq -R -s 'split("\n")|map(select(length>0))')"

echo "[]" > "$TMP_RES"

for rg in "${RGS[@]}"; do
  tmpl_path="$OUTDIR/resGrp-${rg}.network.json"
  if [[ ! -s "$tmpl_path" ]]; then
    cat > "$tmpl_path" <<'EOF'
{ "$schema":"https://schema.management.azure.com/schemas/2019-04-01/deploymentTemplate.json#", "contentVersion":"1.0.0.0", "resources":[] }
EOF
  fi

  # compute deps with cycle-break and optional strip
  dep_list_json="$(jq -n \
    --arg rg "$rg" \
    --argjson edges "$EDGES_JSON" \
    --arg nocr "$NO_CROSS_RG_DEPS" \
    '
    def pairs: [ $edges[] | split("|") | {a:.[0], b:.[1]} ];
    def rev($x;$y): any(pairs[]; .a==$y and .b==$x);
    if $nocr == "true" then [] else
      [ pairs[]
        | select(.a==$rg and .a != .b)
        | select( (rev(.a;.b) | not) or ($rg > .b) )
        | .b ] | unique
    end
    '
  )"

  # Use 4-arg resourceId(subscription().subscriptionId, RG, type, name)
  jq -n \
    --arg rg "$rg" \
    --argfile tmpl "$tmpl_path" \
    --argjson deps "$dep_list_json" \
    '{
      "type": "Microsoft.Resources/deployments",
      "apiVersion": "2021-04-01",
      "name": ("dep-" + $rg),
      "resourceGroup": $rg,
      "properties": {
        "mode": "Incremental",
        "expressionEvaluationOptions": {"scope":"inner"},
        "template": $tmpl
      },
      "dependsOn": ($deps | map("[resourceId(subscription().subscriptionId,\u0027" + . + "\u0027,\u0027Microsoft.Resources/deployments\u0027,\u0027dep-" + . + "\u0027)]"))
    }' \
  | jq --slurpfile cur "$TMP_RES" '$cur[0] + [.]' > "$TMP_RES.tmp"
  mv "$TMP_RES.tmp" "$TMP_RES"
done

jq -n --arg version "$VERSION" --slurpfile resources "$TMP_RES" \
'{ "$schema":"https://schema.management.azure.com/schemas/2019-04-01/deploymentTemplate.json#",
   "contentVersion":"1.0.0.0",
   "metadata":{ "x-ngs-version":$version, "x-generated-utc": (now|todate) },
   "resources": $resources[0] }' > "$SW"

jq -n --arg version "$VERSION" \
  --argjson rgs "$(printf "%s\n" "${RGS[@]}" | jq -R -s 'split("\n")|map(select(length>0))')" \
  --argjson edges "$EDGES_JSON" \
  '{ "version":$version, "resourceGroups":$rgs, "rawEdges":$edges }' > "$REPORT"

log_info "Done. Outputs in: $OUTDIR"
log_info " - $(basename "$SW")"
log_info " - resGrp-*.network.json"
log_info " - report.json"

exit 0
