#!/usr/bin/env bash
set -euo pipefail

# Hetzner Cloud Monthly Cost Estimator
# - Uses live pricing from /pricing
# - Sums current resources in your project
# - Prints both NET (default) or GROSS (VAT) prices
#
# Usage:
#   HCLOUD_TOKEN=xxx ./hcloud-monthly-costs.sh [--gross]
#   (or place HCLOUD_TOKEN in a .env file next to this script)
#
# Notes:
# - Backups are estimated at 20% of a server's monthly price when enabled.
# - Traffic overages and Object Storage are not included.
# - Primary IPv6 are free; IPv4 are billed monthly.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${HC_PRICE_ENV_FILE:-}"
if [[ -z "$ENV_FILE" ]]; then
  if [[ -f "$SCRIPT_DIR/.env" ]]; then
    ENV_FILE="$SCRIPT_DIR/.env"
  elif [[ -f ./.env ]]; then
    ENV_FILE="./.env"
  fi
fi

if [[ -n "$ENV_FILE" && -f "$ENV_FILE" ]]; then
  # Allow bare KEY=VALUE entries to populate the environment
  set -a
  # shellcheck disable=SC1090
  source "$ENV_FILE"
  set +a
fi

API="https://api.hetzner.cloud/v1"
AUTH_HEADER="Authorization: Bearer ${HCLOUD_TOKEN:-}"
if [[ -z "${HCLOUD_TOKEN:-}" ]]; then
  echo "Error: Please export HCLOUD_TOKEN first." >&2
  exit 1
fi

PRICE_KIND="net"   # or 'gross'
if [[ "${1:-}" == "--gross" ]]; then PRICE_KIND="gross"; fi

# --- Helpers ---------------------------------------------------------------

api() {
  # $1: path (e.g., servers?page=1&per_page=50)
  curl -fsSL -H "$AUTH_HEADER" -H "Content-Type: application/json" "$API/$1"
}

# fetch all pages for a collection endpoint; prints concatenated items as a JSON array
# $1: collection path (e.g., "servers"); $2: top-level key (e.g., "servers")
fetch_all() {
  local path="$1"
  local key="$2"
  local page=1
  local per_page=50
  local first=1
  echo -n '['
  while :; do
    local resp
    resp="$(api "$path?page=$page&per_page=$per_page")"
    local items
    items="$(jq -c ".${key}[]" <<<"$resp")"
    if [[ -z "$items" ]]; then
      break
    fi
    while IFS= read -r line; do
      if [[ $first -eq 0 ]]; then echo -n ','; fi
      echo -n "$line"
      first=0
    done <<< "$items"
    # pagination: stop if there's no next_page
    local next_page
    next_page="$(jq -r '.meta.pagination.next_page' <<<"$resp" 2>/dev/null || echo null)"
    if [[ "$next_page" == "null" || -z "$next_page" ]]; then
      break
    fi
    page=$next_page
  done
  echo ']'
}

# Return monthly price for a server type in a given location
# args: server_type_name location_name
price_server_type_monthly() {
  local st="$1" loc="$2"
  jq -rn --arg st "$st" --arg loc "$loc" --arg kind "$PRICE_KIND" \
    '$PRICING
     | .pricing.server_types[]
     | select(.name==$st)
     | .prices[]
     | select(.location==$loc)
     | .price_monthly[$kind]
    ' --argjson PRICING "$PRICING_JSON"
}

# Return monthly price for a load balancer type in a given location
price_lb_type_monthly() {
  local lbt="$1" loc="$2"
  jq -rn --arg lbt "$lbt" --arg loc "$loc" --arg kind "$PRICE_KIND" \
    '$PRICING
     | .pricing.load_balancer_types[]
     | select(.name==$lbt)
     | .prices[]
     | select(.location==$loc)
     | .price_monthly[$kind]
    ' --argjson PRICING "$PRICING_JSON"
}

# Per-GB-month for volumes (block storage)
price_volume_per_gb_month() {
  jq -rn --arg kind "$PRICE_KIND" \
    '
      # Prefer price_per_gb_month, fall back to per_gb_month
      try ($PRICING.pricing.volume.price_per_gb_month[$kind]) //
      try ($PRICING.pricing.volume.per_gb_month[$kind]) //
      try ($PRICING.pricing.volumes.price_per_gb_month[$kind]) // 0
    ' \
    --argjson PRICING "$PRICING_JSON"
}

# Primary IP monthly price per type (ipv4/ipv6)
price_primary_ip_monthly() {
  local iptype="$1" # ipv4 or ipv6
  jq -rn --arg iptype "$iptype" --arg kind "$PRICE_KIND" \
    '
      # Try multiple known shapes
      try ($PRICING.pricing.primary_ip[$iptype].price_monthly[$kind]) //
      try ($PRICING.pricing.primary_ip.price_monthly[$iptype][$kind]) //
      try ($PRICING.pricing.primary_ips[$iptype].price_monthly[$kind]) //
      try ($PRICING.pricing.primary_ips.price_monthly[$iptype][$kind]) // 0
    ' \
    --argjson PRICING "$PRICING_JSON"
}

# Floating IP (legacy) monthly price (if present)
price_floating_ip_monthly() {
  jq -rn --arg kind "$PRICE_KIND" \
    'try ($PRICING.pricing.floating_ip.price_monthly[$kind]) // 0' \
    --argjson PRICING "$PRICING_JSON"
}

# Snapshots per-GB-month
price_snapshot_per_gb_month() {
  jq -rn --arg kind "$PRICE_KIND" \
    '
      # Prefer price_per_gb_month; support legacy keys
      try ($PRICING.pricing.snapshot.price_per_gb_month[$kind]) //
      try ($PRICING.pricing.snapshot.per_gb_month[$kind]) //
      try ($PRICING.pricing.snapshots.price_per_gb_month[$kind]) //
      try ($PRICING.pricing.image.price_per_gb_month[$kind]) // 0
    ' \
    --argjson PRICING "$PRICING_JSON"
}

# --- Fetch pricing (once) --------------------------------------------------

PRICING_JSON="$(api pricing)"

# --- Gather resources ------------------------------------------------------

SERVERS_JSON="$(fetch_all servers servers)"
VOLUMES_JSON="$(fetch_all volumes volumes)"
LBS_JSON="$(fetch_all load_balancers load_balancers)"
PRIMARYIPS_JSON="$(fetch_all primary_ips primary_ips)"
# Legacy floating IPs (may be empty)
FLOATINGIPS_JSON="$(fetch_all floating_ips floating_ips 2>/dev/null || echo '[]')"
# Snapshots are "images" of type "snapshot"
SNAPSHOTS_JSON="$(api 'images?type=snapshot&per_page=50' | jq -c '.images')"

# --- Compute costs ---------------------------------------------------------

# Servers (by type & location); include 20% backup add-on if enabled
server_total=0
server_breakdown="$(jq -c '
  [ .[] | {
      name: .name,
      server_type: .server_type.name,
      location: .datacenter.location.name,
      backups_enabled: (.backup_window != null)
    } ]
' <<<"$SERVERS_JSON")"

servers_cost_sum=0
servers_backup_sum=0
while read -r srv; do
  stype="$(jq -r '.server_type' <<<"$srv")"
  loc="$(jq -r '.location' <<<"$srv")"
  price="$(price_server_type_monthly "$stype" "$loc")"
  # if a location-specific price is missing, fall back to the first listed price
  if [[ -z "$price" || "$price" == "null" ]]; then
    price="$(jq -rn --arg st "$stype" --arg kind "$PRICE_KIND" \
      '$PRICING.pricing.server_types[] | select(.name==$st) | .prices[0].price_monthly[$kind]' \
      --argjson PRICING "$PRICING_JSON")"
  fi
  price="${price:-0}"
  servers_cost_sum="$(jq -n "$servers_cost_sum + ($price // 0)")"
  if [[ "$(jq -r '.backups_enabled' <<<"$srv")" == "true" ]]; then
    backup_add="$(jq -n "$price * 0.20")"
    servers_backup_sum="$(jq -n "$servers_backup_sum + $backup_add")"
  fi
done < <(jq -c '.[]' <<<"$server_breakdown")

# Volumes
vol_gb_total="$(jq '[ .[].size ] | add // 0' <<<"$VOLUMES_JSON")"
vol_price_per_gb="$(price_volume_per_gb_month)"
volumes_cost="$(jq -n "($vol_gb_total // 0) * ($vol_price_per_gb // 0)")"

# Load Balancers
lb_cost_sum=0
while read -r lb; do
  lbt="$(jq -r '.load_balancer_type.name' <<<"$lb")"
  loc="$(jq -r '.location.name' <<<"$lb")"
  price="$(price_lb_type_monthly "$lbt" "$loc")"
  if [[ -z "$price" || "$price" == "null" ]]; then
    price="$(jq -rn --arg lbt "$lbt" --arg kind "$PRICE_KIND" \
      '$PRICING.pricing.load_balancer_types[] | select(.name==$lbt) | .prices[0].price_monthly[$kind]' \
      --argjson PRICING "$PRICING_JSON")"
  fi
  price="${price:-0}"
  lb_cost_sum="$(jq -n "$lb_cost_sum + ($price // 0)")"
done < <(jq -c '.[]' <<<"$LBS_JSON")

# Primary IPs (new model)
pip_v4_count="$(jq '[ .[] | select(.type=="ipv4") ] | length' <<<"$PRIMARYIPS_JSON")"
pip_v6_count="$(jq '[ .[] | select(.type=="ipv6") ] | length' <<<"$PRIMARYIPS_JSON")"
pip_v4_price="$(price_primary_ip_monthly ipv4)"
pip_v6_price="$(price_primary_ip_monthly ipv6)"
primary_ips_cost="$(jq -n "($pip_v4_count * ($pip_v4_price // 0)) + ($pip_v6_count * ($pip_v6_price // 0))")"

# Floating IPs (legacy, if any)
fip_count="$(jq 'length' <<<"$FLOATINGIPS_JSON" 2>/dev/null || echo 0)"
fip_price="$(price_floating_ip_monthly)"
floating_ips_cost="$(jq -n "($fip_count // 0) * ($fip_price // 0)")"

# Snapshots (sum over disk_size GB)
snap_gb_total="$(jq '[ .[].disk_size ] | add // 0' <<<"$SNAPSHOTS_JSON")"
snap_per_gb="$(price_snapshot_per_gb_month)"
snapshots_cost="$(jq -n "($snap_gb_total // 0) * ($snap_per_gb // 0)")"

vol_price_per_gb_display="$vol_price_per_gb"
if [[ -z "$vol_price_per_gb_display" || "$vol_price_per_gb_display" == "null" ]]; then
  vol_price_per_gb_display="n/a"
fi

snap_per_gb_display="$snap_per_gb"
if [[ -z "$snap_per_gb_display" || "$snap_per_gb_display" == "null" ]]; then
  snap_per_gb_display="n/a"
fi

# Totals
servers_cost="$(jq -n "$servers_cost_sum")"
backups_cost="$(jq -n "$servers_backup_sum")"
total="$(jq -n "$servers_cost + $backups_cost + $volumes_cost + $lb_cost_sum + $primary_ips_cost + $floating_ips_cost + $snapshots_cost")"

# --- Output ---------------------------------------------------------------

currency="€"
kind_label="$( [[ "$PRICE_KIND" == "gross" ]] && echo "GROSS (incl. VAT)" || echo "NET (excl. VAT)" )"

# Ensure consistent number formatting for printf
export LC_NUMERIC=C

printf "\nHetzner Cloud Monthly Cost Estimate (%s)\n" "$kind_label"
printf "===========================================\n"
printf "Servers:                %8.2f %s\n" "$servers_cost" "$currency"
printf "  Backups (20%%):        %8.2f %s\n" "$backups_cost" "$currency"
printf "Volumes:                %8.2f %s  (Total size: %s GB @ %s/GB)\n" \
  "$volumes_cost" "$currency" "${vol_gb_total:-0}" "$vol_price_per_gb_display"
printf "Load Balancers:         %8.2f %s\n" "$lb_cost_sum" "$currency"
printf "Primary IPs:            %8.2f %s  (%s IPv4, %s IPv6)\n" \
  "$primary_ips_cost" "$currency" "${pip_v4_count:-0}" "${pip_v6_count:-0}"
if [[ "${fip_count:-0}" -gt 0 ]]; then
  printf "Floating IPs (legacy):  %8.2f %s  (%s)\n" "$floating_ips_cost" "$currency" "$fip_count"
fi
printf "Snapshots:              %8.2f %s  (Total size: %s GB @ %s/GB)\n" \
  "$snapshots_cost" "$currency" "${snap_gb_total:-0}" "$snap_per_gb_display"
printf -- "-------------------------------------------\n"
printf "TOTAL:                  %8.2f %s\n\n" "$total" "$currency"

printf '\n'
printf '%s\n' "Per-Resource Costs"
printf '%s\n' "------------------"

# Servers per-resource costs
servers_count="$(jq 'length // 0' <<<"$server_breakdown")"
servers_count="${servers_count:-0}"
printf '\n'
printf '%s\n' "Servers (${servers_count}):"
if [[ "$servers_count" -gt 0 ]]; then
  while read -r srv; do
    name="$(jq -r '.name // "(unnamed)"' <<<"$srv")"
    stype="$(jq -r '.server_type' <<<"$srv")"
    loc="$(jq -r '.location' <<<"$srv")"
    backups_enabled="$(jq -r '.backups_enabled' <<<"$srv")"
    price="$(price_server_type_monthly "$stype" "$loc")"
    if [[ -z "$price" || "$price" == "null" ]]; then
      price="$(jq -rn --arg st "$stype" --arg kind "$PRICE_KIND" \
        '$PRICING.pricing.server_types[] | select(.name==$st) | .prices[0].price_monthly[$kind]' \
        --argjson PRICING "$PRICING_JSON")"
    fi
    price="${price:-0}"
    if [[ "$backups_enabled" == "true" ]]; then
      backup_add="$(jq -n "$price * 0.20")"
      printf '  - %s: %8.2f %s (backup +%0.2f %s)\n' "$name" "$price" "$currency" "$backup_add" "$currency"
    else
      printf '  - %s: %8.2f %s\n' "$name" "$price" "$currency"
    fi
  done < <(jq -c '.[]' <<<"$server_breakdown")
else
  printf '  %s\n' "(none)"
fi

# Volumes per-resource costs
volumes_count="$(jq 'length // 0' <<<"$VOLUMES_JSON")"
volumes_count="${volumes_count:-0}"
printf '\n'
printf '%s\n' "Volumes (${volumes_count}):"
if [[ "$volumes_count" -gt 0 ]]; then
  while read -r vol; do
    vname="$(jq -r '.name // ("volume-" + (.id|tostring))' <<<"$vol")"
    vsize="$(jq -r '.size // 0' <<<"$vol")"
    vcost="$(jq -n "($vsize // 0) * ($vol_price_per_gb // 0)")"
    printf '  - %s (%s GB): %8.2f %s\n' "$vname" "$vsize" "$vcost" "$currency"
  done < <(jq -c '.[]' <<<"$VOLUMES_JSON")
else
  printf '  %s\n' "(none)"
fi

# Load balancers per-resource costs
lbs_count="$(jq 'length // 0' <<<"$LBS_JSON")"
lbs_count="${lbs_count:-0}"
printf '\n'
printf '%s\n' "Load Balancers (${lbs_count}):"
if [[ "$lbs_count" -gt 0 ]]; then
  while read -r lb; do
    lbname="$(jq -r '.name // ("lb-" + (.id|tostring))' <<<"$lb")"
    lbt="$(jq -r '.load_balancer_type.name' <<<"$lb")"
    loc="$(jq -r '.location.name' <<<"$lb")"
    price="$(price_lb_type_monthly "$lbt" "$loc")"
    if [[ -z "$price" || "$price" == "null" ]]; then
      price="$(jq -rn --arg lbt "$lbt" --arg kind "$PRICE_KIND" \
        '$PRICING.pricing.load_balancer_types[] | select(.name==$lbt) | .prices[0].price_monthly[$kind]' \
        --argjson PRICING "$PRICING_JSON")"
    fi
    price="${price:-0}"
    printf '  - %s: %8.2f %s\n' "$lbname" "$price" "$currency"
  done < <(jq -c '.[]' <<<"$LBS_JSON")
else
  printf '  %s\n' "(none)"
fi

# Primary IPs per-resource costs
primary_ips_count="$(jq 'length // 0' <<<"$PRIMARYIPS_JSON")"
primary_ips_count="${primary_ips_count:-0}"
printf '\n'
printf '%s\n' "Primary IPs (${primary_ips_count}):"
if [[ "$primary_ips_count" -gt 0 ]]; then
  while read -r ip; do
    ipaddr="$(jq -r '.ip // "n/a"' <<<"$ip")"
    iptype="$(jq -r '.type // "n/a"' <<<"$ip")"
    case "$iptype" in
      ipv4) ipprice="$pip_v4_price" ;;
      ipv6) ipprice="$pip_v6_price" ;;
      *) ipprice=0 ;;
    esac
    ipprice="${ipprice:-0}"
    printf '  - %s (%s): %8.2f %s\n' "$ipaddr" "$iptype" "$ipprice" "$currency"
  done < <(jq -c '.[]' <<<"$PRIMARYIPS_JSON")
else
  printf '  %s\n' "(none)"
fi

# Floating IPs per-resource costs (legacy)
fip_count_int="${fip_count:-0}"
printf '\n'
printf '%s\n' "Floating IPs (${fip_count_int}):"
if [[ "$fip_count_int" -gt 0 ]]; then
  while read -r ip; do
    ipaddr="$(jq -r '.ip // "n/a"' <<<"$ip")"
    printf '  - %s: %8.2f %s\n' "$ipaddr" "${fip_price:-0}" "$currency"
  done < <(jq -c '.[]' <<<"$FLOATINGIPS_JSON")
else
  printf '  %s\n' "(none)"
fi

# Snapshots per-resource costs
snapshots_count="$(jq 'length // 0' <<<"$SNAPSHOTS_JSON")"
snapshots_count="${snapshots_count:-0}"
printf '\n'
printf '%s\n' "Snapshots (${snapshots_count}):"
if [[ "$snapshots_count" -gt 0 ]]; then
  while read -r sn; do
    sname="$(jq -r '.description // .name // ("snapshot-" + (.id|tostring))' <<<"$sn")"
    ssize="$(jq -r '.disk_size // 0' <<<"$sn")"
    scost="$(jq -n "($ssize // 0) * ($snap_per_gb // 0)")"
    printf '  - %s (%s GB): %8.2f %s\n' "$sname" "$ssize" "$scost" "$currency"
  done < <(jq -c '.[]' <<<"$SNAPSHOTS_JSON")
else
  printf '  %s\n' "(none)"
fi
