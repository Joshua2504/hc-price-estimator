#!/usr/bin/env bash
set -euo pipefail

# Hetzner Cloud Monthly Cost Estimator
# - Uses live pricing from /pricing
# - Sums current resources in your project
# - Prints both NET (default) or GROSS (VAT) prices
#
# Usage:
#   HCLOUD_TOKEN=xxx ./hcloud-monthly-costs.sh [--gross]
#
# Notes:
# - Backups are estimated at 20% of a server's monthly price when enabled.
# - Traffic overages and Object Storage are not included.
# - Primary IPv6 are free; IPv4 are billed monthly.

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
    '$PRICING.pricing.volume.per_gb_month[$kind]' \
    --argjson PRICING "$PRICING_JSON"
}

# Primary IP monthly price per type (ipv4/ipv6)
price_primary_ip_monthly() {
  local iptype="$1" # ipv4 or ipv6
  jq -rn --arg iptype "$iptype" --arg kind "$PRICE_KIND" \
    '$PRICING.pricing.primary_ip[$iptype].price_monthly[$kind]' \
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
    '$PRICING.pricing.snapshot.per_gb_month[$kind]' \
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
pip_v4_count="$(jq '[ .[] | select(.type==\"ipv4\") ] | length' <<<"$PRIMARYIPS_JSON")"
pip_v6_count="$(jq '[ .[] | select(.type==\"ipv6\") ] | length' <<<"$PRIMARYIPS_JSON")"
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

# Totals
servers_cost="$(jq -n "$servers_cost_sum")"
backups_cost="$(jq -n "$servers_backup_sum")"
total="$(jq -n "$servers_cost + $backups_cost + $volumes_cost + $lb_cost_sum + $primary_ips_cost + $floating_ips_cost + $snapshots_cost")"

# --- Output ---------------------------------------------------------------

currency="€"
kind_label="$( [[ "$PRICE_KIND" == "gross" ]] && echo "GROSS (incl. VAT)" || echo "NET (excl. VAT)" )"

printf "\nHetzner Cloud Monthly Cost Estimate (%s)\n" "$kind_label"
printf "===========================================\n"
printf "Servers:                %8.2f %s\n" "$servers_cost" "$currency"
printf "  Backups (20%%):        %8.2f %s\n" "$backups_cost" "$currency"
printf "Volumes:                %8.2f %s  (Total size: %s GB @ %s/GB)\n" \
  "$volumes_cost" "$currency" "${vol_gb_total:-0}" "${vol_price_per_gb:-0}"
printf "Load Balancers:         %8.2f %s\n" "$lb_cost_sum" "$currency"
printf "Primary IPs:            %8.2f %s  (%s IPv4, %s IPv6)\n" \
  "$primary_ips_cost" "$currency" "${pip_v4_count:-0}" "${pip_v6_count:-0}"
if [[ "${fip_count:-0}" -gt 0 ]]; then
  printf "Floating IPs (legacy):  %8.2f %s  (%s)\n" "$floating_ips_cost" "$currency" "$fip_count"
fi
printf "Snapshots:              %8.2f %s  (Total size: %s GB @ %s/GB)\n" \
  "$snapshots_cost" "$currency" "${snap_gb_total:-0}" "${snap_per_gb:-0}"
printf "-------------------------------------------\n"
printf "TOTAL:                  %8.2f %s\n\n" "$total" "$currency"

