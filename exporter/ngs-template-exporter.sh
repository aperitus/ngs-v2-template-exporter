#!/usr/bin/env bash
# NGS v2 – Template Exporter (v2.0.26)
set -euo pipefail
set -o errtrace
trap 'echo "$(date -u +%FT%TZ) ERROR  Failed at ${BASH_SOURCE[0]}:${LINENO}: ${BASH_COMMAND}" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "$SCRIPT_DIR/lib/log.sh" ]]; then source "$SCRIPT_DIR/lib/log.sh"; else
  LOG_LEVEL="${LOG_LEVEL:-info}"; ts() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }
  _lvl() { case "${LOG_LEVEL}" in debug) echo 10;; info) echo 20;; *) echo 20;; esac; }
  _ok()  { local need=20; [[ "${LOG_LEVEL}" == "debug" ]] && need=10; [[ $(_lvl) -le $need ]]; }
  log_info()  { _ok INFO  && echo "$(ts) INFO  $*"; }
  log_debug() { _ok DEBUG && echo "$(ts) DEBUG $*"; }
  log_warn()  { echo "$(ts) WARN  $*" >&2; }
  log_err()   { echo "$(ts) ERROR $*" >&2; }
fi

VERSION="2.0.26"

# ---------- Preflight ----------
req_az="2.40.0"
req_jq="1.6"

version_ge() { local va; va=$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -n1); [[ "$va" == "$1" ]]; }
need_cmd() { command -v "$1" >/dev/null 2>&1 || { log_err "Missing dependency: $1"; exit 2; }; }

need_cmd az
need_cmd jq

AZ_VER="$(az --version 2>/dev/null | awk '/^azure-cli/ {print $2; exit}')"
JQ_VER="$(jq --version 2>/dev/null | sed -E 's/^jq-//')"

if [[ -n "${AZ_VER:-}" ]] && ! version_ge "$AZ_VER" "$req_az"; then
  log_err "azure-cli ${AZ_VER} detected; require >= ${req_az}. Please run: az upgrade"; exit 2; fi
if [[ -n "${JQ_VER:-}" ]] && ! version_ge "$JQ_VER" "$req_jq"; then
  log_err "jq ${JQ_VER} detected; require >= ${req_jq}. Please install jq 1.6 or newer."; exit 2; fi

_tmp="$(mktemp)"; echo '{}' > "$_tmp"
if ! jq -n --argfile t "$_tmp" '$t' >/dev/null 2>&1; then
  rm -f "$_tmp"; log_err "Your jq build does not support --argfile. Please install jq >= ${req_jq}."; exit 2; fi
rm -f "$_tmp"

SUBSCRIPTION_ID=""
OUTDIR="./out"
RGS=()
REGION_FILTER=""
INCLUDE_NATGW="false"
INCLUDE_VNETGW="false"
INCLUDE_VNET_PEERING="true"
EMIT_TAGS="true"
DUMP_RAW="false"
NO_CROSS_RG_DEPS="false"
STRICT_SAFETY="false"
SKIP_MANAGED="true"   # new: skip 'managed' RGs by default
LOG_LEVEL="${LOG_LEVEL:-info}"

print_help() {
  cat <<'EOF'
Usage: ngs-template-exporter.sh --subscription-id <id> [options]

Options:
  --subscription-id <id>            Required
  --rg <name>                       Repeatable; if omitted, scans entire subscription
  --region-filter <regex>           Filter by Azure region name
  --include natgw                   Emit NAT Gateways and referenced PIPs/Prefixes
  --include vnetgw                  Emit Virtual Network Gateways and PIPs
  --no-vnet-peering                 Do NOT emit VNet peerings (default is emit)
  --outdir <path>                   Output directory (default: ./out)
  --log-level info|debug            Default: info
  --debug                           Alias for --log-level debug
  --dump-raw                        Save raw Azure payloads per RG
  --no-cross-rg-deps                Do NOT add inter-RG dependsOn in wrapper
  --strict-safety                   Fail if dangerous empty arrays/nulls detected
  --no-tags                         Do NOT emit tags (default: emit when present)
  --include-managed                 Include 'managed' resource groups (default: skip)
  -h|--help                         Show help

Requires: azure-cli >= 2.40.0, jq >= 1.6 (with --argfile support)
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --subscription-id) SUBSCRIPTION_ID="$2"; shift 2 ;;
    --rg) RGS+=("$2"); shift 2 ;;
    --outdir) OUTDIR="$2"; shift 2 ;;
    --region-filter) REGION_FILTER="$2"; shift 2 ;;
    --include)
      case "${2:-}" in
        natgw) INCLUDE_NATGW="true" ;;
        vnetgw) INCLUDE_VNETGW="true" ;;
        vnet-peering) INCLUDE_VNET_PEERING="true" ;;
        *) log_err "Unknown include target: ${2:-}"; exit 1 ;;
      esac
      shift 2 ;;
    --no-vnet-peering) INCLUDE_VNET_PEERING="false"; shift ;;
    --log-level) LOG_LEVEL="$2"; shift 2 ;;
    --debug) LOG_LEVEL="debug"; shift ;;
    --dump-raw) DUMP_RAW="true"; shift ;;
    --no-cross-rg-deps) NO_CROSS_RG_DEPS="true"; shift ;;
    --strict-safety) STRICT_SAFETY="true"; shift ;;
    --no-tags) EMIT_TAGS="false"; shift ;;
    --include-managed) SKIP_MANAGED="false"; shift ;;
    -h|--help) print_help; exit 0 ;;
    *) log_err "Unknown arg: $1"; print_help; exit 1 ;;
  esac
done

[[ -z "$SUBSCRIPTION_ID" ]] && { log_err "--subscription-id is required"; exit 1; }
mkdir -p "$OUTDIR"
REPORT="$OUTDIR/report.json"
SW="$OUTDIR/main.subscription.json"
TMP_RES="$OUTDIR/.resources.json"

log_info "NGS Template Exporter v$VERSION starting…"
log_info "Subscription: $SUBSCRIPTION_ID"
[[ ${#RGS[@]} -gt 0 ]] && log_info "RG filter: ${RGS[*]}" || log_info "RG filter: <none>"
[[ -n "$REGION_FILTER" ]] && log_info "Region filter: $REGION_FILTER"
[[ "$DUMP_RAW" == "true" ]] && log_info "Raw dumps: enabled"
[[ "$INCLUDE_NATGW" == "true" ]] && log_info "Emit NAT Gateways: ON"
[[ "$INCLUDE_VNETGW" == "true" ]] && log_info "Emit VNet Gateways: ON"
[[ "$INCLUDE_VNET_PEERING" == "true" ]] && log_info "Emit VNet Peerings: ON" || log_info "Emit VNet Peerings: OFF"
[[ "$EMIT_TAGS" == "true" ]] && log_info "Emit tags: ON" || log_info "Emit tags: OFF"
[[ "$SKIP_MANAGED" == "true" ]] && log_info "Skip managed RGs: ON" || log_info "Skip managed RGs: OFF"

az account set --subscription "$SUBSCRIPTION_ID"

az_json() {
  if out="$(az "$@" -o json 2> >(tee /tmp/ngs-az.err >&2))"; then printf '%s' "$out"
  else log_err "Azure CLI failed: az $* (stderr: /tmp/ngs-az.err)"; printf '[]'; fi
}

# discover RGs if none were provided, optionally skipping "managed" RGs
SKIPPED_MANAGED_RGS=()
if [[ ${#RGS[@]} -eq 0 ]]; then
  # pull all RGs
  all="$(az_json group list --subscription "$SUBSCRIPTION_ID")"
  if [[ "$SKIP_MANAGED" == "true" ]]; then
    # managed RG heuristic: managedBy set OR name ends with "_managed" (case-insensitive)
    mapfile -t RGS < <(echo "$all" | jq -r '[ .[]
        | select( ((.managedBy // null) == null)
                  and ( (.name | test("(?i)_managed$")) | not ) ) ].name | sort | .[]')
    # record skipped for report/log
    mapfile -t SKIPPED_MANAGED_RGS < <(echo "$all" | jq -r '[ .[]
        | select( ((.managedBy // null) != null)
                  or  (.name | test("(?i)_managed$")) ) ].name | sort | .[]')
    for s in "${SKIPPED_MANAGED_RGS[@]:-}"; do log_warn "Skipping managed RG: $s"; done
  else
    mapfile -t RGS < <(echo "$all" | jq -r '.[].name' | sort -u)
  fi
fi

ALL_EDGES=()  # "producerRG|consumerRG" (limited to same subscription)

emit_rg_template() {
  local rg="$1"
  local outfile="$OUTDIR/resGrp-${rg}.network.json"

  local vnets_json rts_json nsgs_json natgw_json vnetgw_json pips_json pipp_json
  vnets_json="$(az_json network vnet list -g "$rg")"
  rts_json="$(az_json network route-table list -g "$rg")"
  nsgs_json="$(az_json network nsg list -g "$rg")"
  natgw_json="$(az_json network nat gateway list -g "$rg")"
  vnetgw_json="$(az_json network vnet-gateway list -g "$rg")"
  pips_json="$(az_json network public-ip list -g "$rg")"
  pipp_json="$(az_json network public-ip prefix list -g "$rg")"

  # Explicit per-VNet peerings list
  local peerings_json="[]"
  if [[ "$INCLUDE_VNET_PEERING" == "true" ]]; then
    mapfile -t vnet_names < <(echo "$vnets_json" | jq -r '.[].name')
    if [[ ${#vnet_names[@]} -eq 0 ]]; then
      log_debug "RG [$rg]: no VNets; skipping peering enumeration"
    else
      for vnet in "${vnet_names[@]}"; do
        [[ -z "${vnet// }" ]] && { log_debug "RG [$rg]: blank VNet name encountered; skipping"; continue; }
        local pj
        pj="$(az_json network vnet peering list -g "$rg" --vnet-name "$vnet")"
        # Warn if any have null remote IDs
        if echo "$pj" | jq -e '[ .[]? | select(.remoteVirtualNetwork.id == null) ] | length > 0' >/dev/null; then
          log_warn "RG [$rg] VNet [$vnet]: skipped peerings with null remoteVirtualNetwork.id"
        fi
        peerings_json="$(jq -n --argjson a "$peerings_json" --argjson b "$pj" '$a + $b')"
      done
    fi
    [[ "$DUMP_RAW" == "true" ]] && echo "$peerings_json" > "$OUTDIR/peerings.${rg}.json"
  fi

  if [[ "$DUMP_RAW" == "true" ]]; then
    echo "$vnets_json"  > "$OUTDIR/vnets.${rg}.json"
    echo "$rts_json"    > "$OUTDIR/routeTables.${rg}.json"
    echo "$nsgs_json"   > "$OUTDIR/nsgs.${rg}.json"
    echo "$natgw_json"  > "$OUTDIR/natGateways.${rg}.json"
    echo "$vnetgw_json" > "$OUTDIR/virtualNetworkGateways.${rg}.json"
    echo "$pips_json"   > "$OUTDIR/publicIPs.${rg}.json"
    echo "$pipp_json"   > "$OUTDIR/publicIPPrefixes.${rg}.json"
  fi

  JQ_PROG="$(mktemp)"
  cat > "$JQ_PROG" <<'JQ'
    def loc_ok($filter): if ($filter == "") then true else (.location // "" | test($filter)) end;
    def has_any_prefix: (.addressPrefix != null) or ((.addressPrefixes // []) | length > 0);
    def choose_prefix_object:
      if ((.addressPrefixes // []) | length) > 0 then { "addressPrefixes": .addressPrefixes }
      else ( if .addressPrefix != null then { "addressPrefix": .addressPrefix } else {} end ) end;
    def strip_service_endpoints: [ (.serviceEndpoints // [])[]? | { service: .service } ];
    def map_delegations:
      [ (.delegations // [])[]?
        | { "name": (.name // "delegation"),
            "properties": { "serviceName": ( .properties.serviceName // .serviceName ) } } ];

    def add_tags($emitTags; $src):
      if ($emitTags == "true") and (($src.tags // null) != null)
      then { "tags": $src.tags } else {} end;

    def rt_resources($rts; $filter; $emitTags):
      [ ($rts[]? | select(loc_ok($filter))) as $rt |
        ({ "type":"Microsoft.Network/routeTables", "apiVersion":"2023-11-01",
           "name":$rt.name, "location":$rt.location }
         + add_tags($emitTags; $rt)
         + { "properties":(
              { "routes":
                [ ($rt.routes // [])[]?
                  | { "name": .name, "properties": (
                        { "addressPrefix": .addressPrefix, "nextHopType": .nextHopType }
                        + (if (.nextHopIpAddress // null) != null then { "nextHopIpAddress": .nextHopIpAddress } else {} end)
                      ) } ] }
              + (if ($rt.disableBgpRoutePropagation // false) then { "disableBgpRoutePropagation": true } else {} end)
            ) } ) ];

    def nsg_resources($nsgs; $filter; $emitTags):
      [ ($nsgs[]? | select(loc_ok($filter))) as $n |
        ({ "type":"Microsoft.Network/networkSecurityGroups", "apiVersion":"2023-11-01",
           "name":$n.name, "location":$n.location }
         + add_tags($emitTags; $n)
         + { "properties":{ "securityRules":
              [ ($n.securityRules // [])[]?
                | { "name": .name,
                    "properties":
                      ({ "priority": .priority, "direction": .direction, "access": .access, "protocol": .protocol }
                       + (if (.sourcePortRange // null) != null then { "sourcePortRange": .sourcePortRange } else {} end)
                       + (if (.destinationPortRange // null) != null then { "destinationPortRange": .destinationPortRange } else {} end)
                       + (if ((.sourcePortRanges // []) | length) > 0 then { "sourcePortRanges": .sourcePortRanges } else {} end)
                       + (if ((.destinationPortRanges // []) | length) > 0 then { "destinationPortRanges": .destinationPortRanges } else {} end)
                       + (if (.sourceAddressPrefix // null) != null then { "sourceAddressPrefix": .sourceAddressPrefix } else {} end)
                       + (if (.destinationAddressPrefix // null) != null then { "destinationAddressPrefix": .destinationAddressPrefix } else {} end)
                       + (if ((.sourceAddressPrefixes // []) | length) > 0 then { "sourceAddressPrefixes": .sourceAddressPrefixes } else {} end)
                       + (if ((.destinationAddressPrefixes // []) | length) > 0 then { "destinationAddressPrefixes": .destinationAddressPrefixes } else {} end)
                       + (if ((.destinationApplicationSecurityGroups // []) | length) > 0 then { "destinationApplicationSecurityGroups": .destinationApplicationSecurityGroups } else {} end)
                       + (if ((.sourceApplicationSecurityGroups // []) | length) > 0 then { "sourceApplicationSecurityGroups": .sourceApplicationSecurityGroups } else {} end)
                       + (if (.description // null) != null then { "description": .description } else {} end)
                      )
                  } ] } } ) ];

    def subnet_objects($v):
      [ ($v.subnets // [])[]?
        | select(has_any_prefix)
        | . as $s
        | { "name": $s.name,
            "properties": (
                ( $s | choose_prefix_object )
              + ( if (( $s.delegations // [] ) | length) > 0
                  then { "delegations": ( $s | map_delegations ) } else {} end )
              + ( if (( $s.serviceEndpoints // [] ) | length) > 0
                  then { "serviceEndpoints": ( $s | strip_service_endpoints ) } else {} end )
              + ( if ($s.privateEndpointNetworkPolicies != null)
                  then { "privateEndpointNetworkPolicies": $s.privateEndpointNetworkPolicies } else {} end )
              + ( if ($s.privateLinkServiceNetworkPolicies != null)
                  then { "privateLinkServiceNetworkPolicies": $s.privateLinkServiceNetworkPolicies } else {} end )
              + ( if ($s.routeTable != null and ($s.routeTable.id // "") != "")
                  then { "routeTable": { "id": $s.routeTable.id } } else {} end )
              + ( if ($s.networkSecurityGroup != null and ($s.networkSecurityGroup.id // "") != "")
                  then { "networkSecurityGroup": { "id": $s.networkSecurityGroup.id } } else {} end )
              + ( if ($s.natGateway != null and ($s.natGateway.id // "") != "")
                  then { "natGateway": { "id": $s.natGateway.id } } else {} end )
            ) } ];

    def vnet_resources($vnets; $filter; $emitTags):
      [ ($vnets[]? | select(loc_ok($filter))) as $v |
        ({ "type":"Microsoft.Network/virtualNetworks", "apiVersion":"2023-11-01",
           "name":$v.name, "location":$v.location }
         + add_tags($emitTags; $v)
         + { "properties":( { "addressSpace": $v.addressSpace } + { "subnets": (subnet_objects($v)) } ),
             "dependsOn":[] } ) ];

    def natgw_resources($natgws; $filter; $emitTags):
      [ ($natgws[]? | select(loc_ok($filter))) as $ng |
        ({ "type":"Microsoft.Network/natGateways", "apiVersion":"2023-11-01",
           "name":$ng.name, "location":$ng.location }
         + add_tags($emitTags; $ng)
         + { "sku": ($ng.sku // null),
             "properties":(
               (if ($ng.idleTimeoutInMinutes // null) != null then { "idleTimeoutInMinutes": $ng.idleTimeoutInMinutes } else {} end)
               + ( if ((($ng.publicIpAddresses // []) | length) > 0) then { "publicIpAddresses": [ $ng.publicIpAddresses[] | { "id": .id } ] } else {} end )
               + ( if ((($ng.publicIpPrefixes // []) | length) > 0) then { "publicIpPrefixes": [ $ng.publicIpPrefixes[] | { "id": .id } ] } else {} end )
             ) } ) ];

    def pip_by_ids($pips; $ids; $emitTags):
      [ $pips[]? | select( (.id // "") as $id | $ids | index($id) ) |
        ({ "type":"Microsoft.Network/publicIPAddresses", "apiVersion":"2023-11-01",
           "name": .name, "location": .location }
         + add_tags($emitTags; .)
         + { "sku": (.sku // null),
             "properties": (
               { "publicIPAllocationMethod": .publicIPAllocationMethod }
               + (if (.publicIPAddressVersion // null) != null then { "publicIPAddressVersion": .publicIPAddressVersion } else {} end)
               + (if (.idleTimeoutInMinutes // null) != null then { "idleTimeoutInMinutes": .idleTimeoutInMinutes } else {} end)
             ) } ) ];

    def pipp_by_ids($pipp; $ids; $emitTags):
      [ $pipp[]? | select( (.id // "") as $id | $ids | index($id) ) |
        ({ "type":"Microsoft.Network/publicIPPrefixes", "apiVersion":"2023-11-01",
           "name": .name, "location": .location }
         + add_tags($emitTags; .)
         + { "sku": (.sku // null),
             "properties": (if (.prefixLength // null) != null then { "prefixLength": .prefixLength } else {} end)
           } ) ];

    def vnetgw_resources($vnetgws; $filter; $emitTags):
      [ ($vnetgws[]? | select(loc_ok($filter))) as $gw |
        ({ "type":"Microsoft.Network/virtualNetworkGateways", "apiVersion":"2023-11-01",
           "name": $gw.name, "location": $gw.location }
         + add_tags($emitTags; $gw)
         + { "properties": (
             { "gatewayType": $gw.gatewayType, "vpnType": $gw.vpnType, "enableBgp": ($gw.enableBgp // false) }
             + (if ($gw.sku // null) != null then { "sku": $gw.sku } else {} end)
             + (if (($gw.ipConfigurations // []) | length) > 0
                 then { "ipConfigurations":
                   [ $gw.ipConfigurations[]
                     | { "name": .name,
                         "properties": (
                           { "subnet": { "id": .properties.subnet.id } }
                           + ( if (.properties.publicIPAddress.id // null) != null
                               then { "publicIPAddress": { "id": .properties.publicIPAddress.id } } else {} end )
                         ) } ] } else {} end)
             + (if ($gw.bgpSettings // null) != null then { "bgpSettings": $gw.bgpSettings } else {} end)
           ) } ) ];

    def peering_resources_from_list($peerings; $vnetName):
      [ ($peerings[]?)
        | select(.remoteVirtualNetwork.id != null)
        | {
            "type":"Microsoft.Network/virtualNetworks/virtualNetworkPeerings",
            "apiVersion":"2023-11-01",
            "name": ($vnetName + "/" + .name),
            "properties": {
              "allowVirtualNetworkAccess": (.allowVirtualNetworkAccess // true),
              "allowForwardedTraffic": (.allowForwardedTraffic // false),
              "allowGatewayTransit": (.allowGatewayTransit // false),
              "useRemoteGateways": (.useRemoteGateways // false),
              "doNotVerifyRemoteGateways": (.doNotVerifyRemoteGateways // false),
              "remoteVirtualNetwork": { "id": .remoteVirtualNetwork.id }
            }
          } ];

    def natgw_needed_pip_ids($natgws): ([ $natgws[]? | (.publicIpAddresses // [])[]?.id ]);
    def natgw_needed_pipp_ids($natgws): ([ $natgws[]? | (.publicIpPrefixes // [])[]?.id ]);
    def vnetgw_needed_pip_ids($vnetgws): ([ $vnetgws[]? | (.ipConfigurations // [])[]? | .properties.publicIPAddress.id ] | map(select(. != null)) );

    def build($vnets;$rts;$nsgs;$natgws;$vnetgws;$pips;$pipp;$peeringsByVnet;$regionFilter;$emitNatgw;$emitVnetgw;$emitPeer;$emitTags):
      ( rt_resources($rts;$regionFilter;$emitTags)
        + nsg_resources($nsgs;$regionFilter;$emitTags)
        + vnet_resources($vnets;$regionFilter;$emitTags)
        + ( if $emitPeer=="true" then
              [ $vnets[]? | select(loc_ok($regionFilter)) | .name as $vn
                | peering_resources_from_list($peeringsByVnet[$vn]; $vn)[]? ]
            else [] end )
        + ( if $emitNatgw=="true" then natgw_resources($natgws;$regionFilter;$emitTags) else [] end )
        + ( if $emitNatgw=="true" then pip_by_ids($pips; natgw_needed_pip_ids($natgws);$emitTags) else [] end )
        + ( if $emitNatgw=="true" then pipp_by_ids($pipp; natgw_needed_pipp_ids($natgws);$emitTags) else [] end )
        + ( if $emitVnetgw=="true" then vnetgw_resources($vnetgws;$regionFilter;$emitTags) else [] end )
        + ( if $emitVnetgw=="true" then pip_by_ids($pips; vnetgw_needed_pip_ids($vnetgws);$emitTags) else [] end )
      );

    {
      "$schema":"https://schema.management.azure.com/schemas/2019-04-01/deploymentTemplate.json#",
      "contentVersion":"1.0.0.0",
      "resources": build($vnets;$rts;$nsgs;$natgws;$vnetgws;$pips;$pipp;$peeringsByVnet;$regionFilter;$emitNatgw;$emitVnetgw;$emitPeer;$emitTags)
    }
JQ

  # Build name->peerings map object for jq: { "<vnetName>": [ ...peerings... ], ... }
  local peer_map="{}"
  if [[ "$INCLUDE_VNET_PEERING" == "true" ]]; then
    for vnet in $(echo "$vnets_json" | jq -r '.[].name'); do
      [[ -z "${vnet// }" ]] && continue
      local this_p
      this_p="$(echo "$peerings_json" | jq --arg vn "$vnet" '[ .[]? | select(.id | strings and (contains("/virtualNetworks/"+$vn+"/virtualNetworkPeerings/"))) ]')"
      peer_map="$(jq -n --arg vn "$vnet" --argjson map "$peer_map" --argjson arr "$this_p" '$map + { ($vn): $arr }')"
    done
  fi

  local template
  if ! template="$(jq -n -f "$JQ_PROG" \
        --arg regionFilter "$REGION_FILTER" \
        --arg emitNatgw "$INCLUDE_NATGW" \
        --arg emitVnetgw "$INCLUDE_VNETGW" \
        --arg emitPeer "$INCLUDE_VNET_PEERING" \
        --arg emitTags "$EMIT_TAGS" \
        --argjson vnets "$vnets_json" \
        --argjson rts "$rts_json" \
        --argjson nsgs "$nsgs_json" \
        --argjson natgws "$natgw_json" \
        --argjson vnetgws "$vnetgw_json" \
        --argjson pips "$pips_json" \
        --argjson pipp "$pipp_json" \
        --argjson peeringsByVnet "$peer_map")"; then
    log_err "Template build failed for RG [$rg] — writing skeleton."
    template='{ "$schema":"https://schema.management.azure.com/schemas/2019-04-01/deploymentTemplate.json#", "contentVersion":"1.0.0.0", "resources":[] }'
  fi
  rm -f "$JQ_PROG"

  echo "$template" | jq '.' > "$outfile"
  log_info "RG [$rg]: wrote resGrp-${rg}.network.json"

  # Safety scan
  if jq -e '
      .resources[]? | select(.type=="Microsoft.Network/virtualNetworks") | .properties.subnets[]? |
      (.properties.serviceEndpoints == [] or .properties.delegations == [] or .properties.privateEndpointNetworkPolicies == null or .properties.privateLinkServiceNetworkPolicies == null)
    ' "$outfile" >/dev/null; then
    if [[ "$STRICT_SAFETY" == "true" ]]; then
      log_err "STRICT SAFETY: explicit empties/nulls detected in $outfile"; exit 3
    else
      log_warn "Safety: detected potential empties/nulls; review $outfile."
    fi
  fi

  # Dependency edges from peerings (only within current subscription)
  if [[ "$INCLUDE_VNET_PEERING" == "true" ]]; then
    local edges
    edges="$(echo "$peer_map" | jq -r --arg rg "$rg" --arg sub "$SUBSCRIPTION_ID" '
      [ to_entries[]
        | .value[]?
        | .remoteVirtualNetwork.id
        | select(. != null)
        | capture("/subscriptions/(?<sub>[^/]+)/resourceGroups/(?<prodRG>[^/]+)/providers/(?<rtype>Microsoft[.]Network/virtualNetworks)/(?<rname>[^/]+)$")
        | select(.sub == $sub)
        | "\(.prodRG)|\($rg)" ] | .[]?')"
    if [[ -n "$edges" ]]; then
      while IFS= read -r line; do [[ -n "$line" ]] && ALL_EDGES+=("$line"); done <<< "$edges"
    fi
  fi
}

# Emit for each RG
az account set --subscription "$SUBSCRIPTION_ID"
if [[ ${#RGS[@]} -eq 0 ]]; then
  # (already populated above; but keep fallback)
  mapfile -t RGS < <(az_json group list --subscription "$SUBSCRIPTION_ID" | jq -r '.[].name' | sort -u)
fi
for rg in "${RGS[@]}"; do
  emit_rg_template "$rg"
done

# Build wrapper
EDGES_JSON="$(printf "%s\n" "${ALL_EDGES[@]:-}" | awk 'NF' | sort -u | jq -R -s 'split("\n")|map(select(length>0))')"
echo "[]" > "$TMP_RES"

for rg in "${RGS[@]}"; do
  tmpl_path="$OUTDIR/resGrp-${rg}.network.json"
  if [[ ! -s "$tmpl_path" ]]; then
    cat > "$tmpl_path" <<'EOF'
{ "$schema":"https://schema.management.azure.com/schemas/2019-04-01/deploymentTemplate.json#", "contentVersion":"1.0.0.0", "resources":[] }
EOF
  fi

  dep_list_json="$(jq -n \
    --arg rg "$rg" \
    --argjson edges "$EDGES_JSON" \
    --arg nocr "$NO_CROSS_RG_DEPS" \
    '
    def pairs: [ $edges[] | split("|") | {prod:.[0], cons:.[1]} ];
    def rev($a;$b): any(pairs[]; .prod==$b and .cons==$a);
    if $nocr == "true" then [] else
      [ pairs[]
        | select(.cons==$rg and .prod != .cons)
        | select( (rev(.prod;.cons) | not) or ($rg > .prod) )
        | .prod ] | unique
    end' )"

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
      "dependsOn": ($deps | map("[resourceId(subscription().subscriptionId, '\''\(.)'\'', '\''Microsoft.Resources/deployments'\'', '\''dep-\(.)'\'')]"))
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
  --argjson skipped "$(printf "%s\n" "${SKIPPED_MANAGED_RGS[@]:-}" | jq -R -s 'split("\n")|map(select(length>0))')" \
  '{ "version":$version, "resourceGroups":$rgs, "rawEdges":$edges, "skippedManagedResourceGroups": $skipped }' > "$REPORT"

log_info "Done. Outputs in: $OUTDIR"
log_info " - main.subscription.json"
log_info " - resGrp-*.network.json"
log_info " - report.json"
exit 0
